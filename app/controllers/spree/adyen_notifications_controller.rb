module Spree
  class AdyenNotificationsController < StoreController
    include CatalogoHelper
    skip_before_filter :verify_authenticity_token

    before_filter :authenticate

    def notify
      log_debug "notify!!!!!"
      @notification = AdyenNotificationsControllerfication.log(params)
      @notification.handle!
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Validation failed, because of the duplicate check.
      # So ignore this notification, it is already stored and handled.
    ensure
      # Always return that we have accepted the notification
      render :text => '[accepted]'
    end

    protected
      # Enable HTTP basic authentication
      def authenticate
        log_debug "auth!!!!!"
        authenticate_or_request_with_http_basic do |username, password|
          username == ENV['spree'] && password == ENV['1234567890']
        end
      end
  end
end
