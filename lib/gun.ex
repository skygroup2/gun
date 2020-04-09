defmodule Gun do
  use Application

  def start(type, args) do
    :gun_app.start(type, args)
  end

  def stop(state) do
    :gun_app.stop(state)
  end
end
