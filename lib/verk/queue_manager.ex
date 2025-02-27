defmodule Verk.QueueManager do
  @moduledoc """
  QueueManager interacts with redis to dequeue jobs from the specified queue.
  """

  use GenServer
  require Logger
  alias Verk.{DeadSet, RetrySet, Time, Job, InProgressQueue}

  @default_stacktrace_size 5

  @external_resource "priv/mrpop_lpush_src_dest.lua"
  @mrpop_lpush_src_dest_script_sha Verk.Scripts.sha("mrpop_lpush_src_dest")

  @max_jobs 100

  defmodule State do
    @moduledoc false
    defstruct [:queue_name, :redis, :node_id, :track_node_id]
  end

  @doc """
  Returns the atom that represents the QueueManager of the `queue`.
  """
  @spec name(binary | atom) :: atom
  def name(queue) do
    String.to_atom("#{queue}.queue_manager")
  end

  @doc false
  def start_link(queue_manager_name, queue_name) do
    GenServer.start_link(__MODULE__, [queue_name], name: queue_manager_name)
  end

  @doc """
  Pop a job from the assigned queue and reply with it if not empty.
  """
  def dequeue(queue_manager, n, timeout \\ 5000) do
    GenServer.call(queue_manager, {:dequeue, n}, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
  end

  @doc """
  Add job to be retried in the assigned queue.
  """
  def retry(queue_manager, job, exception, stacktrace, timeout \\ 5000) do
    now = Time.now() |> DateTime.to_unix()
    GenServer.call(queue_manager, {:retry, job, now, exception, stacktrace}, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
  end

  @doc """
  Acknowledges that a job was processed.
  """
  def ack(queue_manager, job) do
    GenServer.cast(queue_manager, {:ack, job})
  end

  @doc """
  Removes a malformed job from the inprogress queue.
  """
  def malformed(queue_manager, job) do
    GenServer.cast(queue_manager, {:malformed, job})
  end

  @doc """
  Enqueues inprogress jobs back to the queue.
  """
  def enqueue_inprogress(queue_manager) do
    GenServer.call(queue_manager, :enqueue_inprogress)
  end

  @doc """
  Connects to redis.
  """
  def init([queue_name]) do
    node_id = Confex.fetch_env!(:verk, :local_node_id)
    start_opts = Confex.get_env(:verk, :redis_start_opts, [])

    Logger.info("Connecting to redis with: #{inspect(start_opts)}")

    {:ok, redis} = Redix.start_link(Confex.get_env(:verk, :redis_url), start_opts)
    Verk.Scripts.load(redis)

    track_node_id = Application.get_env(:verk, :generate_node_id, false)

    state = %State{
      queue_name: queue_name,
      redis: redis,
      node_id: node_id,
      track_node_id: track_node_id
    }

    Logger.info("Queue Manager started for queue #{queue_name}")
    {:ok, state}
  end

  @doc false
  def handle_call(:enqueue_inprogress, _from, state) do
    case InProgressQueue.enqueue_in_progress(state.queue_name, state.node_id, state.redis) do
      {:ok, [0, m]} ->
        Logger.info("Added #{m} jobs.")

        Logger.info(
          "No more jobs to be added to the queue #{state.queue_name} from inprogress list."
        )

        {:reply, :ok, state}

      {:ok, [n, m]} ->
        Logger.info("Added #{m} jobs.")

        Logger.info(
          "#{n} jobs still to be added to the queue #{state.queue_name} from inprogress list."
        )

        {:reply, :more, state}

      {:error, reason} ->
        Logger.error(
          "Failed to add jobs back to queue #{state.queue_name} from inprogress. Error: #{
            inspect(reason)
          }"
        )

        {:stop, :redis_failed, state}
    end
  end

  def handle_call({:dequeue, n}, _from, state = %State{track_node_id: false}) do
    case Redix.command(state.redis, mrpop_lpush_src_dest(state.node_id, state.queue_name, n)) do
      {:ok, jobs} ->
        {:reply, jobs, state}

      {:error, %Redix.Error{message: message}} ->
        Logger.error("Failed to fetch jobs: #{message}")
        {:stop, :redis_failed, :redis_failed, state}

      {:error, _} ->
        {:reply, :redis_failed, state}
    end
  end

  def handle_call({:dequeue, n}, _from, state = %State{track_node_id: true}) do
    case Redix.pipeline(state.redis, [
           ["MULTI"],
           Verk.Node.add_node_redis_command(state.node_id),
           Verk.Node.add_queue_redis_command(state.node_id, state.queue_name),
           mrpop_lpush_src_dest(state.node_id, state.queue_name, n),
           ["EXEC"]
         ]) do
      {:ok, response} ->
        jobs = response |> List.last() |> List.last()
        {:reply, jobs, state}

      {:error, %Redix.Error{message: message}} ->
        Logger.error("Failed to fetch jobs: #{message}")
        {:stop, :redis_failed, :redis_failed, state}

      {:error, _} ->
        {:reply, :redis_failed, state}
    end
  end

  def handle_call({:retry, job, failed_at, exception, stacktrace}, _from, state) do
    retry_count = (job.retry_count || 0) + 1
    job = build_retry_job(job, retry_count, failed_at, exception, stacktrace)

    if retry_count <= (job.max_retry_count || Job.default_max_retry_count()) do
      RetrySet.add!(job, failed_at, state.redis)
    else
      Logger.info("Max retries reached to job_id #{job.jid}, job: #{inspect(job)}")
      DeadSet.add!(job, failed_at, state.redis)
    end

    {:reply, :ok, state}
  end

  defp build_retry_job(job, retry_count, failed_at, exception, stacktrace) do
    job = %{
      job
      | error_backtrace: format_stacktrace(stacktrace),
        error_message: Exception.message(exception),
        retry_count: retry_count
    }

    if retry_count > 1 do
      # Set the retried_at if this job was already retried at least once
      %{job | retried_at: failed_at}
    else
      # Set the failed_at if this the first time the job failed
      %{job | failed_at: failed_at}
    end
  end

  @doc false
  def handle_cast({:ack, job}, state) do
    case Redix.command(state.redis, [
           "LREM",
           inprogress(state.queue_name, state.node_id),
           "-1",
           job.original_json
         ]) do
      {:ok, 1} -> :ok
      _ -> Logger.error("Failed to acknowledge job #{inspect(job)}")
    end

    {:noreply, state}
  end

  @doc false
  def handle_cast({:malformed, job}, state) do
    case Redix.command(state.redis, [
           "LREM",
           inprogress(state.queue_name, state.node_id),
           "-1",
           job
         ]) do
      {:ok, 1} -> :ok
      _ -> Logger.error("Failed to acknowledge job #{inspect(job)}")
    end

    {:noreply, state}
  end

  defp inprogress(queue_name, node_id) do
    "inprogress:#{queue_name}:#{node_id}"
  end

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace_limit =
      Confex.get_env(:verk, :failed_job_stacktrace_size, @default_stacktrace_size)

    Exception.format_stacktrace(Enum.slice(stacktrace, 0..(stacktrace_limit - 1)))
  end

  defp format_stacktrace(stacktrace), do: inspect(stacktrace)

  defp mrpop_lpush_src_dest(node_id, queue_name, n) do
    [
      "EVALSHA",
      @mrpop_lpush_src_dest_script_sha,
      2,
      "queue:#{queue_name}",
      inprogress(queue_name, node_id),
      min(@max_jobs, n)
    ]
  end
end
