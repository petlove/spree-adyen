module Spree
  module AdyenCommon
    extend ActiveSupport::Concern

    class RecurringDetailsNotFoundError < StandardError; end
    class MissingCardSummaryError < StandardError; end

    included do
      preference :api_username, :string
      preference :api_password, :string
      preference :merchant_account, :string

      def merchant_account
        ENV['ADYEN_MERCHANT_ACCOUNT'] || preferred_merchant_account
      end

      def provider_class
        ::Adyen::API
      end

      def provider
        ::Adyen.configuration.api_username = (ENV['ADYEN_API_USERNAME'] || preferred_api_username)
        ::Adyen.configuration.api_password = (ENV['ADYEN_API_PASSWORD'] || preferred_api_password)
        ::Adyen.configuration.default_api_params[:merchant_account] = merchant_account

        provider_class
      end

      # NOTE Override this with your custom logic for scenarios where you don't
      # want to redirect customer to 3D Secure auth
      def require_3d_secure?(payment)
        true
      end

      # Receives a source object (e.g. CreditCard) and a shopper hash
      def require_one_click_payment?(source, shopper)
        false
      end

      def capture(amount, response_code, gateway_options = {})
        value = { currency: gateway_options[:currency], value: amount }
        response = provider.capture_payment(response_code, value)

        if response.success?
          def response.authorization; psp_reference; end
          def response.avs_result; {}; end
          def response.cvv_result; {}; end
        else
          # TODO confirm the error response will always have these two methods
          def response.to_s
            "#{result_code} - #{refusal_reason}"
          end
        end

        response
      end

      # According to Spree Processing class API the response object should respond
      # to an authorization method which return value should be assigned to payment
      # response_code
      def void(response_code, source, gateway_options = {})
        response = provider.cancel_payment(response_code)

        if response.success?
          def response.authorization; psp_reference; end
        else
          # TODO confirm the error response will always have these two methods
          def response.to_s
            "#{result_code} - #{refusal_reason}"
          end
        end

        response
      end

      def credit(credit_cents, source, response_code, gateway_options)
        amount = { currency: gateway_options[:currency], value: credit_cents }
        response = provider.refund_payment response_code, amount

        if response.success?
          def response.authorization; psp_reference; end
        else
          def response.to_s
            refusal_reason
          end
        end

        response
      end

      def disable_recurring_contract(source)
        response = provider.disable_recurring_contract source.user_id, source.gateway_customer_profile_id
        if response.success?
          source.update_column :gateway_customer_profile_id, nil
        else
          logger.error(Spree.t(:gateway_error))
          logger.error("  #{response.to_yaml}")
          raise Core::GatewayError.new(gateway_message(response))
        end
      end

      def gateway_message(response)
        response.try(:fault_code) || (response.fault_message || response.refusal_reason)
      end

      def authorise3d(md, pa_response, ip, env)
        browser_info = {
          browser_info: {
            accept_header: env['HTTP_ACCEPT'],
            user_agent: env['HTTP_USER_AGENT']
          }
        }

        provider.authorise3d_payment(md, pa_response, ip, browser_info)
      end

      def build_authorise_details(payment)
        if payment.request_env.is_a?(Hash) && require_3d_secure?(payment)
          {
            browser_info: {
              accept_header: payment.request_env['HTTP_ACCEPT'],
              user_agent: payment.request_env['HTTP_USER_AGENT']
            },
            recurring: true,
            installments: {
              value: payment.installments
            }
          }
        else
          { recurring: true,
            installments: {
              value: payment.installments
            }
          }
        end
      end

      def build_amount_on_profile_creation(payment)
        { currency: payment.currency, value: payment.money.money.cents }
      end

      private

        def set_up_contract(source, card, user, shopper_ip)
          options = {
            order_id: "User-#{user.id}",
            customer_id: user.id,
            email: user.email,
            ip: shopper_ip,
          }

          response = authorize_on_card 0, source, options, card, { recurring: true }

          if response.success?
            last_digits = response.additional_data["cardSummary"]
            if last_digits.blank? && payment_profiles_supported?
              note = "Payment was authorized but could not fetch last digits.
                      Please request last digits to be sent back to support payment profiles"
              raise Adyen::MissingCardSummaryError, note
            end

            source.last_digits = last_digits
            begin
              fetch_and_update_contract source, options[:customer_id]
            rescue Spree::AdyenCommon::RecurringDetailsNotFoundError => e
              Rails.logger.error("Could not update contract after set up contract #{e.inspect}")
            end

          else
            response.error
          end
        end

        def authorize_on_card(amount, source, gateway_options, card, options = { recurring: false })
          reference = gateway_options[:order_id]

          amount = { currency: gateway_options[:currency], value: amount }
          shopper = { reference: gateway_options[:document_number],
                      email: gateway_options[:email],
                      name: { firstname: gateway_options[:first_name], lastname: gateway_options[:last_name]},
                      ip: gateway_options[:ip],
                      statement: "Order # #{gateway_options[:order_id]}",
                      social_security_number: gateway_options[:document_number],
                      telephone_number: gateway_options[:telephone_number]
                    }

          # It might deprecate #create_on_profile call for address
          # TODO: review
          { bill_address: :billing_address, ship_address: :shipping_address }.each do |address_type, key|
            addr = gateway_options[key]
            next if addr.nil?
            address = {
              street: [addr[:address1],addr[:address2]].compact.join(' '),
              city: addr[:city],
              state: addr[:state],
              postal_code: addr[:zipcode],
              country: 'BR',
              house_number: addr[:house_number]
            }
            shopper[address_type] = address
          end

          options.merge!({ installments: { value: gateway_options[:installments]} })

          response = decide_and_authorise reference, amount, shopper, source, card, options
          log_authorize_details(:authorize_on_card, reference, amount, options, response)

          # Needed to make the response object talk nicely with Spree payment/processing api
          if response.success? && valid_message?(response)
            begin
              fetch_and_update_contract source, shopper[:reference]
            rescue Spree::AdyenCommon::RecurringDetailsNotFoundError => e
              Rails.logger.error("Could not update contract after authorize #{e.inspect}")
            end
            def response.authorization; psp_reference; end
            def response.avs_result; {}; end
            def response.cvv_result; {}; end
          else
            def response.to_s
              "#{result_code} - #{refusal_reason}"
            end
          end

          response
        end

        def valid_message?(response)
          binding.pry
          response.refusal_reason_raw.to_s.include?('Transacao autorizada')
        end

        def decide_and_authorise(reference, amount, shopper, source, card, options)
          recurring_detail_reference = source.gateway_customer_profile_id
          card_cvc = source.verification_value

          if card_cvc.blank? && require_one_click_payment?(source, shopper)
            raise Core::GatewayError.new("You need to enter the card verificationv value")
          end

          begin
            fetch_and_update_contract(source, shopper[:reference])
          rescue Spree::AdyenCommon::RecurringDetailsNotFoundError => e
            Rails.logger.error "Could not update contract before authorize, order: '#{reference}', source: '#{source.inspect}', document_number: '#{shopper[:reference]}', error: '#{e.class}', message: '#{e.message}'"
            Rails.logger.error e.backtrace.reject { |n| n =~ /rails/ }.join("\n")
          end

          if require_one_click_payment?(source, shopper) && recurring_detail_reference.present?
            provider.authorise_one_click_payment reference, amount, shopper, card_cvc, recurring_detail_reference, nil, options
          elsif source.gateway_customer_profile_id.present?
            provider.authorise_recurring_payment reference, amount, shopper, source.gateway_customer_profile_id, nil, options
          else
            provider.authorise_payment reference, amount, shopper, card, options
          end
        end

        def create_profile_on_card(payment, card)
          return if payment.pending?
          unless payment.source.gateway_customer_profile_id.present?
            shopper = {
              reference: payment.document_number,
              email: payment.order.email,
              ip: payment.order.last_ip_address,
              name: shopper_name(payment.order),
              statement: "Order # #{payment.order.number}",
              social_security_number: payment.document_number,
              telephone_number: payment.order.user.try(:phone)
            }

            [:bill_address, :ship_address].each do |address_type|
              address = payment.order.send(address_type)
              shopper[address_type] = address.to_gateway if address.present? && address.respond_to?(:to_gateway)
            end

            amount = build_amount_on_profile_creation payment
            options = build_authorise_details payment

            response = provider.authorise_payment payment.order.number, amount, shopper, card, options
            log_authorize_details(:create_profile_on_card, "#{payment.order.number}-#{payment.identifier}", amount, options, response)
            payment.response_code = response.psp_reference if response && response.respond_to?(:psp_reference)

            if response.success? && valid_message?(response)
              last_digits = response.additional_data["cardSummary"]
              if last_digits.blank? && payment_profiles_supported?
                note = "Payment was authorized but could not fetch last digits.
                        Please request last digits to be sent back to support payment profiles"
                raise Adyen::MissingCardSummaryError, note
              end

              payment.source.last_digits = last_digits
              begin
                fetch_and_update_contract payment.source, shopper[:reference]
              rescue Spree::AdyenCommon::RecurringDetailsNotFoundError => e
                Rails.logger.error("Could not update contract after create profile #{e.inspect}")
              end

              #sets response_code to payment object when creating profiles
              payment.pend!

            elsif response.respond_to?(:enrolled_3d?) && response.enrolled_3d?
              raise Adyen::Enrolled3DError.new(response, payment.payment_method)
            else
              logger.error(Spree.t(:gateway_error))
              logger.error("  #{response.to_yaml}")
              Rails.logger.error("[Spree::AdyenCommon::CreateProfileOnCard] Error creating payment. "\
                                 "Order: #{payment.order.number} Payment identifier: #{payment.identifier} "\
                                 "Error: #{response.try(:to_json)}"
                )
              raise Core::GatewayError.new(gateway_message(response) || 'refused')
            end

            response
          end
        end

        def fetch_and_update_contract(source, document_number)
          list = provider.list_recurring_details(document_number)
          raise RecurringDetailsNotFoundError.new(list.inspect) unless list.details.present?

          card = list.details.find { |c| ::Adyen::CardDetails.new(c) == source }
          raise RecurringDetailsNotFoundError.new(source.inspect) unless card.present?

          all_cards = equal_cards(source, card)

          all_cards.each do |c|
            c.update_columns(
              month: card[:card][:expiry_date].month,
              year: card[:card][:expiry_date].year,
              name: card[:card][:holder_name],
              cc_type: card[:variant],
              last_digits: card[:card][:number],
              gateway_customer_profile_id: card[:recurring_detail_reference],
              document_number: document_number
            )
          end
        end

        def equal_cards(source, card)
          return [source] unless source.user

          cards = source.user.credit_cards.where(
            last_digits: card[:card][:number],
            cc_type: card[:variant],
            month: card[:card][:expiry_date].month.to_i,
            year: card[:card][:expiry_date].year.to_i
          )

          cards << source unless cards.include?(source)
          cards
        end
    end

    module ClassMethods
    end

  private
    def shopper_name(order)
      bill_address = order.try(:bill_address)
      { firstname: bill_address.firstname, lastname: bill_address.lastname } if bill_address
    end

    def log_authorize_details(method_name, reference, amount, options, response)
      order_number = reference.to_s.split('-')[0]
      Rails.logger.info "[AdyenCommom] [#{method_name}] Order: #{order_number} MerchantReference: #{reference} amount: #{amount} options: #{options}"
      Rails.logger.info "[AdyenCommom] [#{method_name}] Order: #{order_number} MerchantReference: #{reference} response: #{response.try(:body) if response}"
      Rails.logger.info "[AdyenCommom] [#{method_name}] Order: #{order_number} ValidMessage: #{valid_message?(response)}"
    rescue
      Rails.logger.error "[AdyenCommom] [#{method_name}] Order: #{order_number} MerchantReference: #{reference} amount: #{amount} ERROR WITHOUT BODY"
    end
  end
end
