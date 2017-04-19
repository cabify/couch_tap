module CouchTap
  module Callbacks
    class Callback
      def execute(data)
        raise NotImplementedError
      end
    end
  end
end

