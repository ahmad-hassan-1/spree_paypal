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
      if params[:order_id]
        order = Spree::Order.find(params[:order_id])
      else
        order = current_order
      end
      payment_method = Spree::PaymentMethod.find(params[:payment_method_id])
      service = SpreePaypal::PaypalService.new(payment_method)
      response = service.capture_order(params[:orderID])

      if response['status'] == 'COMPLETED'
        order.update_from_params(params, permitted_checkout_attributes)
        process_spree_payment(order, payment_method, response)
        order.save
        order.next until order.completed? || order.errors.any?
        order.finalize!
        begin
          if params['order']['email_me']
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
        rescue
        end
        render json: { status: 'success', details: response }, status: :ok
      else
        render json: { error: 'Capture failed' }, status: :unprocessable_entity
      end
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
          response_code: paypal_response['id'],
          source: paypal_source, # You could create a PayPal-specific payment source if necessary
          avs_response: paypal_response['payer']['payer_id']
        )
      else
        order.payments.create(
          payment_method: payment_method,
          amount: order.total,
          state: 'checkout',
          response_code: paypal_response['id'],
          source: paypal_source, # You could create a PayPal-specific payment source if necessary
          avs_response: paypal_response['payer']['payer_id']
        )
      end

      # Only transition the order if it's not already completed
      # payment.complete! unless payment.completed?
    end
  end
end