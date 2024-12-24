{
  description = "Elixir-Julia port communication via escript";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpks-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        elixir = pkgs.beam.packages.erlang.elixir;
        julia = pkgs.julia-bin;
        
        juliaScript = pkgs.writeText "data_processor.jl" ''
          using JSON, Statistics

          # Process data from STDIN
          while !eof(stdin)
              line = readline(stdin)
              data = JSON.parse(line)
              
              # Process the data
              numbers = data["numbers"]
              result = Dict(
                  "mean" => mean(numbers),
                  "std" => std(numbers),
                  "input_length" => length(numbers)
              )
              
              # Write result back to stdout
              println(JSON.json(result))
              flush(stdout)
          end
        '';
        
        elixirScript = pkgs.writeText "port_processor.exs" ''
          Mix.install([
            {:jason, "1.4.4"}
          ])

          defmodule JuliaPort do
            use GenServer

            def start_link(opts \\ []) do
              GenServer.start_link(__MODULE__, opts)
            end

            def process_data(pid, numbers) when is_list(numbers) do
              GenServer.call(pid, {:process, numbers}, :infinity)
            end

            @impl true
            def init(opts) do
              script_path = opts[:script_path]
              julia_path = System.get_env("JULIA_PATH") ||
                raise "JULIA_PATH environment variable not set"

              port = Port.open({:spawn, "#{julia_path} #{script_path}"}, [
                :binary,
                :exit_status,
                {:line, 1024},
                :use_stdio,
                :stderr_to_stdout
              ])
              
              {:ok, %{port: port, pending_requests: %{}}}
            end

            @impl true
            def handle_call({:process, numbers}, from, %{port: port} = state) do
              request = %{numbers: numbers}
              Port.command(port, "#{Jason.encode!(request)}\n")
              new_state = put_in(state.pending_requests[from], request)
              {:noreply, new_state}
            end

            @impl true
            def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
              case Jason.decode(line) do
                {:ok, result} ->
                  {from, _request} = Enum.find(state.pending_requests, fn {_from, req} ->
                    req.numbers |> length() == result["input_length"]
                  end)
                  
                  GenServer.reply(from, {:ok, result})
                  new_state = update_in(state.pending_requests, &Map.delete(&1, from))
                  {:noreply, new_state}
                  
                {:error, _} = error ->
                  case Map.keys(state.pending_requests) do
                    [from | _] -> 
                      GenServer.reply(from, error)
                      new_state = update_in(state.pending_requests, &Map.delete(&1, from))
                      {:noreply, new_state}
                    [] ->
                      {:noreply, state}
                  end
              end
            end

            @impl true
            def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
              {:stop, {:port_exited, status}, state}
            end

            @impl true
            def terminate(_reason, %{port: port} = _state) do
              Port.close(port)
            end
          end

          numbers = case System.argv() do
            ["--numbers", json] ->
              case Jason.decode(json) do
                {:ok, nums} when is_list(nums) -> nums
                {:error, _} -> 
                  IO.puts "Error: Invalid JSON format"
                  System.halt(1)
                _ -> 
                  IO.puts "Error: Input must be a JSON array"
                  System.halt(1)
              end
            _ ->
              IO.puts "Usage: nix run .#process -- --numbers '[1,2,3]'"
              System.halt(1)
          end

          {:ok, pid} = JuliaPort.start_link(script_path: System.get_env("JULIA_SCRIPT_PATH"))

          case JuliaPort.process_data(pid, numbers) do
            {:ok, result} ->
              IO.puts Jason.encode!(result, pretty: true)
              System.halt(0)
            {:error, reason} ->
              IO.puts "Error: #{inspect(reason)}"
              System.halt(1)
          end
        '';
        
        setupScript = pkgs.writeShellScriptBin "elixir-setup" ''
          echo "Setting up Elixir environment..."
          mkdir -p .nix-mix .nix-hex
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          ${elixir}/bin/mix local.hex --force
          ${elixir}/bin/mix local.rebar --force
          
          # Install Julia packages
          export JULIA_DEPOT_PATH=$PWD/.julia
          ${julia}/bin/julia -e 'using Pkg; Pkg.add(["JSON", "Statistics"])'
          echo "Setup complete."
        '';

        runScript = pkgs.writeShellScriptBin "run-elixir-script" ''
          if [ ! -d ".nix-mix" ] || [ ! -d ".nix-hex" ] || [ ! -d ".julia" ]; then
            echo "Running initial setup..."
            ${setupScript}/bin/elixir-setup
          fi
          
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          export JULIA_DEPOT_PATH=$PWD/.julia
          export ELIXIR_ERL_OPTIONS="+fnu"
          export JULIA_PATH="${julia}/bin/julia"
          export JULIA_SCRIPT_PATH="${juliaScript}"
          
          ${elixir}/bin/elixir ${elixirScript} "$@"
        '';
      in
      {
        packages = {
          process = runScript;
          setup = setupScript;
        };
        apps = {
          process = flake-utils.lib.mkApp {
            drv = runScript;
          };
          setup = {
            type = "app";
            program = "${setupScript}/bin/elixir-setup";
          };
        };
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            elixir
            beam.packages.erlang.elixir_ls
            julia-bin
          ];
          shellHook = ''
            mkdir -p .nix-mix .nix-hex .julia
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export JULIA_DEPOT_PATH=$PWD/.julia
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          '';
        };
      }
    );
}
