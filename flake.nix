{
  description = "Elixir escript for reflecting numbers using Jason";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        elixir = pkgs.beam.packages.erlang.elixir;

        elixirScript = pkgs.writeText "reflect.exs" ''
          Mix.install([
            {:jason, "1.4.4"}
          ])

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
              IO.puts "Usage: nix run .#reflect -- --numbers '[1,2,3]'"
              System.halt(1)
          end

          IO.puts Jason.encode!(numbers, pretty: true)
        '';

        setupScript = pkgs.writeShellScriptBin "elixir-setup" ''
          echo "Setting up Elixir environment..."
          mkdir -p .nix-mix .nix-hex
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          ${elixir}/bin/mix local.hex --force
          ${elixir}/bin/mix local.rebar --force
          echo "Elixir setup complete. You can now run the reflection script."
        '';

        runScript = pkgs.writeShellScriptBin "run-elixir-script" ''
          if [ ! -d ".nix-mix" ] || [ ! -d ".nix-hex" ]; then
            echo "Running initial setup..."
            ${setupScript}/bin/elixir-setup
          fi

          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          export ELIXIR_ERL_OPTIONS="+fnu"
          ${elixir}/bin/elixir ${elixirScript} "$@"
        '';
      in
      {
        packages = {
          reflect = runScript;
          setup = setupScript;
        };
        apps = {
          reflect = flake-utils.lib.mkApp {
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
          ];
          shellHook = ''
            mkdir -p .nix-mix .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
          '';
        };
      }
    );
}
