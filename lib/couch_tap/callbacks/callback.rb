module CouchTap
  module Callbacks
    class Callback
      def execute(data, statsd, logger)
        raise NotImplementedError
      end
    end
  end
end

