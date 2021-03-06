# This is a base calculator for shipping calcualations using the ActiveShipping plugin.  It is not intended to be
# instantiated directly.  Create subclass for each specific shipping method you wish to support instead.
#
# Digest::MD5 is used for cache_key generation.
require 'digest/md5'
require_dependency 'spree/calculator'

module Spree
  module Calculator::Shipping
    module ActiveShipping
      class Base < ShippingCalculator
        include ActiveShipping

        def self.service_name
          self.description
        end

        def available?(package)
          # helps the available? method determine
          # if rates are avaiable for this service
          # before calling the carrier for rates
          is_package_shippable?(package)

          !compute(package).nil?
        rescue Spree::ShippingError
          false
        end

        def compute_package(package)
          order = package.order
          stock_location = package.stock_location

          origin = build_location(stock_location)
          destination = build_location(order.ship_address)
          options = build_options(stock_location)

          rates_result = retrieve_rates_from_cache(package, origin, destination, options)
          Rails.logger.info "ActiveShipping Log: #{rates_result.inspect}"
          return nil if rates_result.kind_of?(Spree::ShippingError)
          return nil if rates_result.empty?
          rate = rates_result[self.class.description]

          return nil unless rate
          rate = rate.to_f + (Spree::ActiveShipping::Config[:handling_fee].to_f || 0.0)

          # divide by 100 since active_shipping rates are expressed as cents
          rate / 100.0
        end

        def timing(line_items)
          order = line_items.first.order
          # TODO: Figure out where stock_location is supposed to come from.
          origin= ::ActiveShipping::Location.new(country: stock_location.country.iso,
                               city: stock_location.city,
                               state: (stock_location.state ? stock_location.state.abbr : stock_location.state_name),
                               zip: stock_location.zipcode)
          addr = order.ship_address
          destination = ::ActiveShipping::Location.new(country: addr.country.iso,
                                     state: (addr.state ? addr.state.abbr : addr.state_name),
                                     city: addr.city,
                                     zip: addr.zipcode)
          timings_result = Rails.cache.fetch(cache_key(package)+"-timings") do
            retrieve_timings(origin, destination, packages(order))
          end
          raise timings_result if timings_result.kind_of?(Spree::ShippingError)
          return nil if timings_result.nil? || !timings_result.is_a?(Hash) || timings_result.empty?
          timings_result[self.description]

        end

        protected

        # weight limit in ounces or zero (if there is no limit)
        def max_weight_for_country(country)
          0
        end

        private

        # check for known limitations inside a package
        # that will limit you from shipping using a service
        def is_package_shippable? package
          # check for weight limits on service
          country_weight_error? package
        end

        def country_weight_error? package
          max_weight = max_weight_for_country(package.order.ship_address.country)
          raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.") unless valid_weight_for_package?(package, max_weight)
        end

        # zero weight check means no check
        # nil check means service isn't available for that country
        def valid_weight_for_package? package, max_weight
          return false if max_weight.nil?
          return true if max_weight.zero?
          package.weight <= max_weight
        end

        def retrieve_rates(origin, destination, shipment_packages, options = {})
          begin
            response = carrier.find_rates(origin, destination, shipment_packages, options)
            # turn this beastly array into a nice little hash
            rates = response.rates.collect do |rate|
              service_name = rate.service_name.encode("UTF-8")
              [CGI.unescapeHTML(service_name), rate.price]
            end
            rate_hash = Hash[*rates.flatten]
            return rate_hash
          rescue ::ActiveShipping::Error => e
            Rails.logger.info "ActiveShipping Error: #{ e.message }"
            if e.class == ::ActiveShipping::ResponseError && e.response.is_a?(::ActiveShipping::Response)
              params = e.response.params
              if params.has_key?("Response") && params["Response"].has_key?("Error") && params["Response"]["Error"].has_key?("ErrorDescription")
                message = params["Response"]["Error"]["ErrorDescription"]
              # Canada Post specific error message
              elsif params.has_key?("eparcel") && params["eparcel"].has_key?("error") && params["eparcel"]["error"].has_key?("statusMessage")
                message = e.response.params["eparcel"]["error"]["statusMessage"]
              else
                message = e.message
              end
            else
              message = e.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key, error #write error to cache to prevent constant re-lookups
            raise error
          end

        end


        def retrieve_timings(origin, destination, packages, options = {})
          begin
            if carrier.respond_to?(:find_time_in_transit)
              response = carrier.find_time_in_transit(origin, destination, packages, options)
              return response
            end
          rescue ::ActiveShipping::ResponseError => re
            if re.response.is_a?(::ActiveShipping::Response)
              params = re.response.params
              if params.has_key?("Response") && params["Response"].has_key?("Error") && params["Response"]["Error"].has_key?("ErrorDescription")
                message = params["Response"]["Error"]["ErrorDescription"]
              else
                message = re.message
              end
            else
              message = re.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key+"-timings", error #write error to cache to prevent constant re-lookups
            raise error
          end
        end

        def convert_package_to_weights_array(package)
          multiplier = Spree::ActiveShipping::Config[:unit_multiplier]
          default_weight = Spree::ActiveShipping::Config[:default_weight]
          max_weight = get_max_weight(package)

          weights = package.contents.map do |content_item|
            item_weight = content_item.variant.weight.to_f
            item_weight = default_weight if item_weight <= 0
            item_weight *= multiplier

            if max_weight <= 0 || item_weight < max_weight
              item_weight
            else
              raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.")
            end
          end
          weights.flatten.compact.sort
        end

        def convert_package_to_item_packages_array(package)
          multiplier = Spree::ActiveShipping::Config[:unit_multiplier]
          max_weight = get_max_weight(package)
          packages = []

          package.contents.each do |content_item|
            variant  = content_item.variant
            quantity = content_item.quantity
            product  = variant.product

            product.product_packages.each do |product_package|
              if product_package.weight.to_f <= max_weight or max_weight == 0
                quantity.times do
                  packages << [product_package.weight * multiplier, product_package.length, product_package.width, product_package.height]
                end
              else
                raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.")
              end
            end
          end

          packages
        end

        # Used for calculating Dimensional Weight pricing.
        # Override in your own extensions to compute package dimensions,
        # or just leave this alone to keep the default behavior.
        # Sample output: [9, 6, 3]
        def convert_package_to_dimensions_array(package)
          []
        end

        # Generates an array of Package objects based on the quantities and weights of the variants in the line items
        def packages(package)
          units = Spree::ActiveShipping::Config[:units].to_sym
          packages = []
          weights = convert_package_to_weights_array(package)
          max_weight = get_max_weight(package)
          dimensions = convert_package_to_dimensions_array(package)
          item_specific_packages = convert_package_to_item_packages_array(package)

          if max_weight <= 0
            packages << ::ActiveShipping::Package.new(weights.sum, dimensions, units: units)
          else
            package_weight = 0
            weights.each do |content_weight|
              if package_weight + content_weight <= max_weight
                package_weight += content_weight
              else
                packages << ::ActiveShipping::Package.new(package_weight, dimensions, units: units)
                package_weight = content_weight
              end
            end
            packages << ::ActiveShipping::Package.new(package_weight, dimensions, units: units) if package_weight > 0
          end

          item_specific_packages.each do |package|
            packages << ::ActiveShipping::Package.new(package.at(0), [package.at(1), package.at(2), package.at(3)], units: :imperial)
          end

          packages
        end

        def get_max_weight(package)
          order = package.order
          max_weight = max_weight_for_country(order.ship_address.country)
          max_weight_per_package = Spree::ActiveShipping::Config[:max_weight_per_package] * Spree::ActiveShipping::Config[:unit_multiplier]
          if max_weight.zero? && max_weight_per_package > 0
            max_weight = max_weight_per_package
          elsif max_weight > 0 && max_weight_per_package < max_weight && max_weight_per_package > 0
            max_weight = max_weight_per_package
          end

          max_weight
        end

        def cache_key(package, options = {})
          stock_location = package.stock_location.nil? ? "" : "#{package.stock_location.id}-"
          order = package.order
          ship_address = package.order.ship_address
          contents_hash = Digest::MD5.hexdigest(package.contents.map {|content_item| content_item.variant.id.to_s + "_" + content_item.quantity.to_s }.join("|"))
          option_key = options.map { |k, v| "#{k}=#{v}" }.join(':')
          @cache_key = "#{stock_location}#{carrier.name}-#{order.number}-#{ship_address.country.iso}-#{fetch_best_state_from_address(ship_address)}-#{ship_address.city}-#{ship_address.zipcode}-#{contents_hash}-#{option_key}-#{I18n.locale}".gsub(" ","")
        end

        def fetch_best_state_from_address(address)
          address.state ? address.state.abbr : address.state_name
        end

        def build_location address
          ::ActiveShipping::Location.new(country: address.country.iso,
                                         state: fetch_best_state_from_address(address),
                                         city: address.city,
                                         address1: address.address1,
                                         address2: address.address2,
                                         zip: address.zipcode)
        end

        def build_options(stock)
          options = {}
          if fedex_freight?
            options = {
              freight: {
                payment_type: 'SENDER',
                role: 'SHIPPER',
                account: Spree::ActiveShipping::Config[:fedex_freight_account],
                billing_location:  build_location(stock),
                freight_class: 'CLASS_050',
                packaging: 'PALLET'
              }
            }
          end
          if is_fedex_multi_warehouse? && stock.fedex_key.present? && stock.fedex_password.present? &&
              stock.fedex_account.present? && stock.fedex_login.present?
            options.merge!({
                               key: stock.fedex_key,
                               password: stock.fedex_password,
                               account: stock.fedex_account,
                               login: stock.fedex_login,
                           })
            if fedex_freight? && stock.fedex_freight_account
              options[:freight][:account] = stock.fedex_freight_account
            end
          end
          options
        end



        def fedex_freight?
          carrier.is_a?(::ActiveShipping::FedEx) &&
            (is_a?(Spree::Calculator::Shipping::Fedex::FreightPriority) ||
            is_a?(Spree::Calculator::Shipping::Fedex::FreightEconomy)) &&
            Spree::ActiveShipping::Config[:fedex_freight_account].present?
        end

        def is_fedex_multi_warehouse?
          Spree::ActiveShipping::Config[:fedex_multi_warehouse]
        end

        def retrieve_rates_from_cache(package, origin, destination, options = {})
          Rails.cache.fetch(cache_key(package, options )) do
            shipment_packages = packages(package)
            if shipment_packages.empty?
              {}
            else
              retrieve_rates(origin, destination, shipment_packages, options)
            end
          end
        end
      end
    end
  end
end
