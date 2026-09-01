module Xiki
  module Menu
    class Status
      def self.menu *args, &block
        Xiki::Menu::Git.status(*args, &block)
      end
    end
  end
end
