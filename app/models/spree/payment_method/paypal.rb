module Spree
  class PaymentMethod::Paypal < PaymentMethod
    preference :client_id, :string
    preference :client_secret, :string
    preference :sandbox, :boolean, default: true # Default to sandbox mode

    def payment_source_class
      Spree::Paypal
    end

    def actions
      %w{capture void}
    end

    def purchase(amount, source, options = {})
      ActiveMerchant::Billing::Response.new(true, 'Paypal Gateway', {})
    end

    def auto_capture?
      true
    end

    def supports?(source)
      source.payment_method.is_a?(Spree::PaymentMethod::Paypal)
    end

    def provider_class
      SpreePaypal::PaypalService
    end

    def client_id
      preferred_client_id
    end

    def client_secret
      preferred_client_secret
    end

    def sandbox?
      preferred_sandbox
    end

    def credit(amount_cents, response_code, options = {})
      amount = BigDecimal(amount_cents) / 100

      result = provider_class.new(self).refund_by_capture_id(response_code, amount, options[:originator])

      ActiveMerchant::Billing::Response.new(true, 'PayPal payment refunded', result)
    rescue => e
      ActiveMerchant::Billing::Response.new(false, e.message, {})
    end
  end
end