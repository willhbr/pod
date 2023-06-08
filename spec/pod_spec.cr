require "./spec_helper"

describe Pod::Runner do
  it "builds" do
    result = assert_runner(config(
      "images:
        build_test:
          from: Containerfile.test
          tag: my-image:latest
      "
    )) do |runner|
      runner.build "build_test"
    end
    result[0].should eq("podman build --tag=my-image:latest --file=Containerfile.test .")
  end

  it "runs" do
    result = assert_runner(config(
      "containers:
         run_test:
           name: some-container
           image: my-image:latest
           bind_mounts:
             .: /src
           ports:
             1234: 80
           interactive: true
           autoremove: true
           flags:
             some-flag: 'some value'
      "
    )) do |runner|
      runner.run "run_test", nil, nil
    end
    result[0].should eq(
      "podman run --tty=true --interactive=true --rm=true " +
      "--mount=type=bind,src=.,dst=/src --publish=1234:80 --name=some-container " +
      "--hostname=some-container --label=pod_hash=85d2a8935e49493cbf7efd893d993c531e04a31e" +
      " my-image:latest '--some-flag=some value'")
  end
end
