@testset "train model" begin

    mockData_path = joinpath(splitpath(pathof(DistributedFluxML))[1:end-2]...,"mockData")
    _shard_file_list = ["iris_df_1.jlb",
                        "iris_df_2.jlb",
                        "iris_df_3.jlb"]

    batch_size=8
    epochs = 50

    shard_file_list = [joinpath(mockData_path, sf) for sf in _shard_file_list];

    deser_fut = [@spawnat w global rawData = deserialize(f)
                 for (w, f) in zip(p, shard_file_list)]
    for fut in deser_fut
        wait(fut)
    end
    epoch_length_worker = @fetchfrom p[1] nrow(rawData)
    @everywhere p labels = ["Iris-versicolor", "Iris-virginica", "Iris-setosa"]

    @everywhere p x_array =
        Array(rawData[:,
                      [:sepal_l, :sepal_w,
                       :petal_l, :petal_w
                       ]])

    @everywhere p y_array =
        Flux.onehotbatch(rawData[:,"class"],
                         labels)

    @everywhere p dataChan = Channel(1) do ch
        n_chunk = ceil(Int,size(x_array)[1]/$batch_size)
        x_dat = Flux.chunk(transpose(x_array), n_chunk)
        y_dat = Flux.chunk(y_array, n_chunk)
        for epoch in 1:$epochs
            for d in zip(x_dat, y_dat)
                put!(ch, d)
            end
        end
    end

    @everywhere p datRemChan = RemoteChannel(() -> dataChan, myid())

    trainWorkers_shift = circshift(p, 1)
    # ^^^ shift workers to reuse workers as ^^^
    # ^^^ remote data hosts ^^^
    datRemChansDict = Dict(k => @fetchfrom w datRemChan for (k,w) in zip(p, trainWorkers_shift))
    
    loss_f = Flux.Losses.logitcrossentropy
    opt = Flux.Optimise.ADAM(0.001)

    model = Chain(Dense(4,8),Dense(8,16), Dense(16,3))

    empty!(status_array)
    DistributedFluxML.train!(loss_f, model, datRemChansDict, opt, p; status_chan)

    finished_workers = Set([s[:myid] for s in status_array if s[:statusName] == "do_train_on_remote.finished"])
    test_finshed_res = @test finished_workers == Set(p)

    if isa(test_finshed_res, Test.Pass)
        remote_params = [@fetchfrom w Flux.params(DistributedFluxML.model) for w in p]
        θ = Flux.params(model)
        @test all(θ .≈ remote_params[1])
        @test all(θ .≈ remote_params[2])
        @test all(θ .≈ remote_params[3])
    end

    global log_loss_dict = Dict(w => [(s[:step], log(s[:loss]))
                                      for s in status_array
                                      if s[:statusName] == "do_train_on_remote.step.grad" && s[:myid] == w]
                                for w in p)
    raw_data= vcat(values(log_loss_dict)...)
    raw_data_trunk = [l for l in raw_data if l[1] > epoch_length_worker*1]
    data = DataFrame(raw_data_trunk)
    rename!(data, [:Step, :LLoss])
    global ols = lm(@formula(LLoss ~ Step), data)
    @test coef(ols)[2] < 1e-4 # tests if loss is decaying
    @test ftest(ols.model).pval < 1e-20 # tests if loss is decaying
end