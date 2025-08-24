# .iex.exs
defmodule DevObserver do
  @apps [:wx, :observer, :runtime_tools]

  def ensure_code_paths! do
    root = List.to_string(:code.root_dir())

    Enum.each(@apps, fn app ->
      case Path.wildcard(Path.join(root, "lib/#{app}-*/ebin")) do
        [ebin | _] -> :code.add_pathz(String.to_charlist(ebin))
        _ -> :ok
      end
    end)
  end

  def load! do
    ensure_code_paths!()

    Enum.each(@apps, fn app ->
      case :application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, _}} -> :ok
        _ -> :ok
      end
    end)

    :ok
  end

  def start_observer do
    load!()

    # Avoid compile-time warnings by using dynamic apply.
    # Also bail out gracefully if there is no display.
    if System.get_env("DISPLAY") in [nil, ""] do
      {:error, :no_display}
    else
      try do
        case :erlang.apply(:wx, :new, []) do
          {:wx_ref, _, :wx, _} -> :erlang.apply(:observer, :start, [])
          _ -> {:error, :no_display}
        end
      catch
        _, _ -> {:error, :no_display}
      end
    end
  end
end

# Make :wx / :observer available in this shell
DevObserver.load!()

# Auto-open Observer only if you ask for it
if System.get_env("AUTO_OBSERVER") == "1", do: DevObserver.start_observer()

# Load your helpers (SupTree, etc.) if present
IEx.Helpers.import_file_if_available("scripts/iex_helpers.exs")

# Nice IEx defaults
IEx.configure(inspect: [limit: :infinity])
