defmodule ScryJourney.Card do
  @moduledoc """
  Load and normalize journey card JSON files.

  A journey card defines an executable feature contract:
  - `execution` — which module/function to call
  - `checkpoints` — assertions to verify on the result

  ## Card Format (v1)

      {
        "schema_version": "journey_card/v1",
        "id": "user_registration",
        "name": "User Registration Flow",
        "execution": {
          "type": "module_call",
          "run": {"module": "MyApp.Journeys", "function": "run", "args": [5000], "timeout_ms": 10000}
        },
        "checkpoints": [
          {"id": "user_created", "path": "user.id", "assert": "present"}
        ]
      }
  """

  @doc "Load a journey card from a JSON file path."
  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, json} <- Jason.decode(contents) do
      normalize(json)
    end
  end

  @doc "Normalize a decoded JSON map into a journey card struct."
  def normalize(json) do
    # TODO: validate schema_version, normalize fields
    {:ok, json}
  end
end
