
require 'test_helper'

class QueryExecutorTest < Test::Unit::TestCase

  def setup
    @queue = CouchTap::OperationsQueue.new
  end

  def test_insert_saves_the_data_if_not_full
    executor = config_executor 10

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    assert_equal 0, executor.database[:items].count
  end

  def test_insert_runs_the_query_if_full
    executor = config_executor 2

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(item_to_insert(true, 987))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start
    assert_equal 2, executor.database[:items].count
  end

  def test_insert_fails_rollsback_the_transaction
    executor = config_executor 2

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(false, 123))
    @queue.add_operation(item_to_insert(false, 123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    assert_raises Sequel::UniqueConstraintViolation do
      executor.start
    end

    assert_equal 0, executor.database[:items].count
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 0, sequence[:seq]
    assert_equal nil, sequence[:last_transaction_at]
  end

  def test_delete_saves_the_data_if_not_full
    executor = config_executor 10

    id = 123

    executor.database[:items].insert(item_id: id, name: 'dummy')
    assert_equal 1, executor.database[:items].count

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_delete(id))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    assert_equal 1, executor.database[:items].count
  end

  def test_delete_runs_the_query_if_full
    executor = config_executor 1

    id = 123

    executor.database[:items].insert(item_id: id, name: 'dummy')
    assert_equal 1, executor.database[:items].count

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_delete(id))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    assert_equal 0, executor.database[:items].count
  end

  def test_delete_fails_rollsback_the_transaction
    executor = config_executor 2

    id = 123

    executor.database[:items].insert(item_id: id, name: 'dummy')
    assert_equal 1, executor.database[:items].count

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_delete(id))
    @queue.add_operation(CouchTap::Operations::DeleteOperation.new(:cow, true, :cow_id, 234))
    @queue.add_operation(end_transaction_operation(1))

    assert_raises Sequel::DatabaseError do
      executor.start
    end

    assert_equal 1, executor.database[:items].count
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 0, sequence[:seq]
    assert_equal nil, sequence[:last_transaction_at]
  end

  def test_create_and_delete_same_row
    executor = config_executor 2

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(item_to_delete(123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    t = Time.now
    Timecop.freeze(t) { executor.start }

    assert_equal 0, executor.database[:items].where(item_id: 123).count
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 1, sequence[:seq]
    assert_equal t, sequence[:last_transaction_at]
  end

  def test_includes_whole_row_even_if_batch_gets_oversized
    executor = config_executor 2

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(item_to_insert(true, 234))
    @queue.add_operation(item_to_insert(true, 345))
    @queue.add_operation(item_to_insert(true, 456))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    t = Time.now
    Timecop.freeze(t) { executor.start }

    assert_equal 4, executor.database[:items].count
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 1, sequence[:seq]
    assert_equal t, sequence[:last_transaction_at]
  end

  def test_combined_workload
    executor = config_executor 3

    # Create and destroy item 123
    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(item_to_delete(123))

    # Insert item_to_inserts 234, 345 and 456
    @queue.add_operation(item_to_insert(true, 234))
    @queue.add_operation(item_to_insert(true, 345))
    @queue.add_operation(item_to_insert(true, 456))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    # Update item 234
    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_delete(234))
    @queue.add_operation(item_to_insert(true, 234))

    # Delete item 345
    @queue.add_operation(item_to_delete(345))
    @queue.add_operation(end_transaction_operation(2))
    @queue.close

    t = Time.now
    Timecop.freeze(t) { executor.start }

    assert_equal %w(234 456), executor.database[:items].select(:item_id).to_a.map { |i| i[:item_id] }
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 2, sequence[:seq]
    assert_equal t, sequence[:last_transaction_at]
  end

  def test_delete_nested_items
    executor = config_executor 2

    executor.database.create_table :item_children do
      String :item_id
      String :child_name
    end

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(CouchTap::Operations::InsertOperation.new(:item_children, false, 123, item_id: 123, child_name: 'child name'))
    @queue.add_operation(end_transaction_operation(1))

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_delete(123))
    @queue.add_operation(CouchTap::Operations::InsertOperation.new(:items, true, 123, item_id: 123, count: 2, name: 'another name'))
    @queue.add_operation(CouchTap::Operations::DeleteOperation.new(:item_children, false, :item_id, 123))
    @queue.add_operation(CouchTap::Operations::InsertOperation.new(:item_children, false, 123, item_id: 123, child_name: 'another child name'))
    @queue.add_operation(end_transaction_operation(2))
    @queue.close


    t = Time.now
    Timecop.freeze(t) { executor.start }

    assert_equal [2], executor.database[:items].select(:count).to_a.map{ |i| i[:count] }
    assert_equal ['another child name'], executor.database[:item_children].select(:child_name).to_a.map{ |g| g[:child_name] }
    sequence = executor.database[:couch_sequence].where(name: 'items').first
    assert_equal 2, sequence[:seq]
    assert_equal t, sequence[:last_transaction_at]
  end

  def test_sequence_number_defaults_to_zero
    executor = config_executor 10
    assert_equal 0, executor.seq
  end

  def test_sequence_number_is_loaded_on_initialization
    executor = CouchTap::QueryExecutor.new 'items', @queue, CouchTap::Metrics.new, db: 'sqlite://test.db', batch_size: 10
    initialize_database executor.database
    executor.database[:couch_sequence].where(name: 'items').update(seq: 432)

    executor = CouchTap::QueryExecutor.new 'items', @queue, CouchTap::Metrics.new, db: 'sqlite://test.db', batch_size: 10
    assert_equal 432, executor.seq

    File.delete('test.db')
  end

  def test_running_a_batch_clears_the_buffer
    executor = config_executor 2

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(item_to_insert(true, 234))

    t = Thread.new do
      executor.start
    end
    t.abort_on_exception = true

    sleep 0.1
    assert_equal 2, executor.instance_variable_get(:@buffer).size

    @queue.add_operation(end_transaction_operation(1))
    @queue.close
    t.join

    assert_equal 0, executor.instance_variable_get(:@buffer).size
  end

  def test_timer_signal_runs_the_transaction
    executor = config_executor 200

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.add_operation(CouchTap::Operations::TimerFiredSignal.new)
    @queue.close

    executor.start

    assert_equal 1, executor.database[:items].count
  end

  def test_timer_signal_schedules_the_transaction_to_run
    executor = config_executor 200

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(CouchTap::Operations::TimerFiredSignal.new)
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    assert_equal 1, executor.database[:items].count
  end

  def test_timer_signal_is_skipped_if_last_transaction_ran_too_close
    executor = config_executor  1

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.add_operation(CouchTap::Operations::TimerFiredSignal.new)
    @queue.close

    executor.database.expects(:transaction).once

    executor.start
  end

  def test_empty_batches_are_skipped
    executor = config_executor 1

    @queue.add_operation(CouchTap::Operations::TimerFiredSignal.new)
    @queue.close

    executor.database.expects(:transaction).never

    executor.start
  end

  class SpecialItemInsertCallback < CouchTap::Callbacks::Callback
    def execute(buffer, metrics, logger)
      buffer.insert(CouchTap::Operations::InsertOperation.new(:items, true, 987, item_id: 987))
    end
  end

  def test_runs_pre_transaction_callback
    executor = config_executor 1

    executor.add_pre_transaction_callback(SpecialItemInsertCallback.new)

    @queue.add_operation(begin_transaction_operation)
    @queue.add_operation(item_to_insert(true, 123))
    @queue.add_operation(end_transaction_operation(1))
    @queue.close

    executor.start

    assert_equal 1, executor.database[:items].where(item_id: 987).count
  end

  private

  def config_executor(batch_size, queue = @queue)
    executor = CouchTap::QueryExecutor.new 'items', queue, CouchTap::Metrics.new, db: 'sqlite:/', batch_size: batch_size
    initialize_database executor.database
    return executor
  end


  def initialize_database(connection)
    connection.create_table :items do
      String :item_id
      String :name
      Integer :count
      Float :price
      Time :created_at
      index :item_id, :unique => true
    end
    connection
  end

  def item_to_insert(top_level, id)
    CouchTap::Operations::InsertOperation.new(:items, top_level, id, item_id: id, name: 'dummy', count: rand())
  end

  def item_to_delete(id)
    CouchTap::Operations::DeleteOperation.new(:items, true, :item_id, id)
  end

  def begin_transaction_operation
    CouchTap::Operations::BeginTransactionOperation.new
  end

  def end_transaction_operation(seq)
    CouchTap::Operations::EndTransactionOperation.new(seq)
  end
end
