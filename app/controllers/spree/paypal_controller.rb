module Spree
  class PaypalController < Spree::StoreController
    protect_from_forgery with: :null_session

    def create_order
      if params[:order_id]
        order = Spree::Order.find(params[:order_id])
      else
        order = current_order
      end
      payment_method = Spree::PaymentMethod.find(params[:payment_method_id])

      service = SpreePaypal::PaypalService.new(payment_method)
      response = service.create_order(order)

      if response['id']
        render json: { orderID: response['id'] }, status: :ok
      else
        render json: { error: response['message'] }, status: :unprocessable_entity
      end
    end

    def capture_order
      if params[:order]&.[](:email)&.empty?
        render json: { error: 'Email is required' }, status: :unprocessable_entity
        return
      end

      if params[:order]&.[](:bill_address_attributes).present?
        check_required_fields = %w[firstname lastname address1 city state_id zipcode country_id]
        if params[:order][:bill_address_attributes].values_at(*check_required_fields).any?(&:blank?)
          render json: { error: 'All bill address attributes are required' }, status: :unprocessable_entity
          return
        end
      end

      order = params[:order_id] ? Spree::Order.find(params[:order_id]) : current_order
      payment_method = Spree::PaymentMethod.find(params[:payment_method_id])
      service = SpreePaypal::PaypalService.new(payment_method)

      if order.update_from_params(params, permitted_checkout_attributes)
        Rails.logger.info "Order #{order.number} updated successfully from params"
      else
        Rails.logger.error "Order #{order.number} update failed: #{order.errors.full_messages.join(', ')}"
        render json: { error: 'Order update failed', details: order.errors.full_messages }, status: :unprocessable_entity
        return
      end

      order.reload
      if order.shipments.empty?
        Rails.logger.error "Order #{order.number} has no shipments after update_from_params"
        render json: { error: 'No shipments found for order' }, status: :unprocessable_entity
        return
      end

      response = service.capture_order(params[:orderID])
      if response['status'] != 'COMPLETED'
        Rails.logger.error "PayPal capture failed for order #{order.number}: #{response}"
        render json: { error: 'Capture failed', details: response }, status: :unprocessable_entity
        return
      end

      begin
        process_spree_payment(order, payment_method, response)
      rescue => e
        Rails.logger.error "Payment processing failed for order #{order.number}: #{e.message}"
        render json: { error: 'Payment processing failed', details: e.message }, status: :unprocessable_entity
        return
      end

      begin
        order.next until order.completed? || order.errors.any?
        if order.errors.any?
          Rails.logger.error "Order #{order.number} failed to complete: #{order.errors.full_messages.join(', ')}"
          order.finalize!
        end
      rescue => e
        Rails.logger.error "Order finalization failed for #{order.number}: #{e.message}"
      end

      begin
        if params.dig('order', 'email_me') && order.ship_address.present?
          address = order.ship_address
          gibbon = ::Gibbon::Request.new(api_key: SpreeMailchimpEcommerce.configuration.mailchimp_api_key)
          gibbon.lists(::SpreeMailchimpEcommerce.configuration.mailchimp_list_id)
                .members
                .create(
                  body: {
                    email_address: order.email,
                    status: "subscribed",
                    merge_fields: {
                      FNAME: address.firstname,
                      LNAME: address.lastname,
                      ADDRESS: [
                        address.address1,
                        address.address2,
                        address.city,
                        address.state_name,
                        address.zipcode,
                        address.country_name
                      ].compact.join(', '),
                      PHONE: address.phone
                    }
                  }
                )
        end
      rescue => e
        Rails.logger.error "Mailchimp subscription failed for order #{order.number}: #{e.message}"
      end

      render json: { status: 'success', details: response }, status: :ok
    end

    private

    def process_spree_payment(order, payment_method, paypal_response)
      payer_info = paypal_response.dig('payer', 'name') || {}

      paypal_source = Spree::Paypal.create!(
        payer_id: paypal_response['payer']['payer_id'],
        first_name: payer_info['given_name'],
        last_name: payer_info['surname'],
        email: paypal_response['payer']['email_address'],
        payment_method_id: payment_method.id,
        transaction_id: paypal_response['id']
      )
      payment = order.payments.first
      if payment
        payment.update(
          payment_method: payment_method,
          amount: order.total,
          state: 'checkout',
          response_code: paypal_response.dig("purchase_units", 0, "payments", "captures", 0, "id") || paypal_response['id'],
          source: paypal_source, # You could create a PayPal-specific payment source if necessary
          avs_response: paypal_response['payer']['payer_id']
        )
      else
        order.payments.create(
          payment_method: payment_method,
          amount: order.total,
          state: 'checkout',
          response_code: paypal_response.dig("purchase_units", 0, "payments", "captures", 0, "id") || paypal_response['id'],
          source: paypal_source, # You could create a PayPal-specific payment source if necessary
          avs_response: paypal_response['payer']['payer_id']
        )
      end

      # Only transition the order if it's not already completed
      # payment.complete! unless payment.completed?
    end
  end
end