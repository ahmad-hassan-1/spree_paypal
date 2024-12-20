module Spree
  module OrderDecorator
    # def self.prepended(base)
    #   base.checkout_flow do
    #     go_to_state :address
    #     go_to_state :delivery
    #     go_to_state :payment
    #     go_to_state :confirm
    #     go_to_state :complete
    #   end
    # end
  end
end

Spree::Order.prepend Spree::OrderDecorator