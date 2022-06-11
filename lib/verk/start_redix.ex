defmodule Verk.StartRedis do
  def start_redis("rediss" <> _ = redis_url) do
    Redix.start_link(redis_url, socket_opts: [verify: :verify_none])
  end

  def start_redis(redis_url) do
    Redix.start_link(redis_url)
  end
end
