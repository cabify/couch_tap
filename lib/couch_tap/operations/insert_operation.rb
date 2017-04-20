
module CouchTap
  module Operations
    class InsertOperation
      attr_reader :table, :top_level, :id
      attr_accessor :attributes

      def initialize(table, top_level, id, attributes)
        @table = table
        @top_level = top_level
        @id = id
        @attributes = attributes
      end

      def ==(other)
        other.is_a?(InsertOperation) &&
          table == other.table &&
          top_level == other.top_level &&
          id == other.id &&
          attributes == other.attributes
      end
    end
  end
end
