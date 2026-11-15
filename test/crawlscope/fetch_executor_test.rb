# frozen_string_literal: true

require "test_helper"

class CrawlscopeFetchExecutorTest < Minitest::Test
  class RecordingExecutor
    attr_reader :items

    def call(items)
      @items = items
      items.map { |item| yield(item) }
    end
  end

  def test_map_preserves_input_order
    results = Crawlscope::FetchExecutor.map(name: :threaded, concurrency: 2, items: [3, 1, 2]) do |item|
      item * 10
    end

    assert_equal [30, 10, 20], results
  end

  def test_map_uses_sequential_fallback_for_single_item
    executor = RecordingExecutor.new

    results = Crawlscope::FetchExecutor.map(name: executor, concurrency: 4, items: ["one"]) do |item|
      item.upcase
    end

    assert_equal ["ONE"], results
    assert_nil executor.items
  end

  def test_map_uses_injected_executor_for_parallel_work
    executor = RecordingExecutor.new

    results = Crawlscope::FetchExecutor.map(name: executor, concurrency: 4, items: %w[a b]) do |item|
      item.upcase
    end

    assert_equal %w[A B], results
    assert_equal %w[a b], executor.items
  end

  def test_threaded_executor_reraises_worker_errors_after_scheduling_all_work
    executor = Crawlscope::FetchExecutor.build(name: :threaded, concurrency: 4)
    processed = Concurrent::Array.new

    error = assert_raises(RuntimeError) do
      executor.call([1, 2, 3, 4]) do |item|
        processed << item
        raise "boom #{item}" if item == 2
      end
    end

    assert_equal "boom 2", error.message
    assert_equal [1, 2, 3, 4], processed.sort
  end
end
