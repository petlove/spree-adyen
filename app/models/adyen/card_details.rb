module Adyen
  class CardDetails
    attr_accessor :month, :year, :name, :last_digits, :cc_type
    def initialize(params)
      card = params[:card].to_h.symbolize_keys
      if card[:expiry_date].is_a? Date
        @month = card[:expiry_date].month.to_i
        @year = card[:expiry_date].year.to_i
      end
      @name = card[:holder_name]
      @last_digits = card[:number].to_s
      @cc_type = params[:variant]
    end

    def ==(source)
      source.is_a?(Spree::CreditCard) && source.last_digits == @last_digits
    end
  end
end
