module Spree
  module BaseHelper
    module BaseHelperDecorator
      def self.included(base)
        base.module_eval do
          # Defined because Rails' current_page? helper is not working when Spree is mounted at root.
          def current_spree_page?(url)
            path = request.fullpath.gsub(/^\/\//, "/")
            if url.is_a?(String)
              return path == url
            elsif url.is_a?(Hash)
              return path == spree.url_for(url)
            end
            false
          end

          def link_to_cart(text = nil)
            text = text ? h(text) : I18n.t("spree.cart")
            css_class = nil

            if current_order.nil? || current_order.item_count.zero?
              text = "<span class='glyphicon glyphicon-shopping-cart'></span> #{text}: (#{I18n.t("spree.empty")})"
              css_class = "empty"
            else
              text = "<span class='glyphicon glyphicon-shopping-cart'></span> #{text}: (#{current_order.item_count})  <span class='amount'>#{current_order.display_total.to_html}</span>"
              css_class = "full"
            end

            link_to text.html_safe, spree.cart_path, class: "cart-info #{css_class}"
          end

          # human readable list of variant options
          def variant_options(v, options = {})
            v.options_text
          end

          def meta_data
            object = instance_variable_get("@" + controller_name.singularize)
            meta = {}

            if object.is_a? ActiveRecord::Base
              meta[:keywords] = object.meta_keywords if object[:meta_keywords].present?
              meta[:description] = object.meta_description if object[:meta_description].present?
            end

            if meta[:description].blank? && object.is_a?(Spree::Product)
              meta[:description] = strip_tags(truncate(object.description, length: 160, separator: " "))
            end

            meta.reverse_merge!({
              keywords: current_store.meta_keywords,
              description: current_store.meta_description
            })
            meta
          end

          def meta_data_tags
            meta_data.map do |name, content|
              tag("meta", name: name, content: content)
            end.join("\n")
          end

          def body_class
            @body_class ||= content_for?(:sidebar) ? "two-col" : "one-col"
            @body_class
          end

          def logo(image_path = Spree::Config[:logo])
            link_to image_tag(image_path), spree.root_path
          end

          def flash_messages(opts = {})
            ignore_types = ["order_completed"].concat(Array(opts[:ignore_types]).map(&:to_s) || [])

            flash.each do |msg_type, text|
              unless ignore_types.include?(msg_type)
                concat(content_tag(:div, text, class: "alert alert-#{msg_type}"))
              end
            end
            nil
          end

          def breadcrumbs(taxon, separator = "&nbsp;", breadcrumb_class = "breadcrumb")
            return "" if current_page?("/") || taxon.nil?

            crumbs = [[I18n.t("spree.home"), spree.root_path]]

            crumbs << [I18n.t("spree.products"), products_path]
            if taxon
              crumbs += taxon.ancestors.collect { |a| [a.name, spree.nested_taxons_path(a.permalink)] } unless taxon.ancestors.empty?
              crumbs << [taxon.name, spree.nested_taxons_path(taxon.permalink)]
            end

            separator = raw(separator)

            crumbs.map! do |crumb|
              content_tag(:li, itemscope: "itemscope", itemtype: "http://data-vocabulary.org/Breadcrumb") do
                link_to(crumb.last, itemprop: "url") do
                  content_tag(:span, crumb.first, itemprop: "title")
                end + (crumb == crumbs.last ? "" : separator)
              end
            end

            content_tag(:nav, content_tag(:ol, raw(crumbs.map(&:mb_chars).join), class: breadcrumb_class), id: "breadcrumbs", class: "col-md-12")
          end

          def taxons_tree(root_taxon, current_taxon, max_level = 1)
            return "" if max_level < 1 || root_taxon.children.empty?
            content_tag :div, class: "list-group" do
              root_taxon.children.map do |taxon|
                css_class = current_taxon && current_taxon.self_and_ancestors.include?(taxon) ? "list-group-item active" : "list-group-item"
                link_to(taxon.name, seo_url(taxon), class: css_class) + taxons_tree(taxon, current_taxon, max_level - 1)
              end.join("\n").html_safe
            end
          end

          def available_countries(options = {})
            checkout_zone = Spree::Zone.find_by(name: Spree::Config[:checkout_zone])

            countries = if checkout_zone && checkout_zone.kind == "country"
              checkout_zone.country_list
            else
              Spree::Country.all
            end

            countries.collect do |country|
              country.name = I18n.t("spree.country_names.#{country.iso}", default: country.name)
              country
            end.sort_by { |c| c.name.parameterize }
          end

          def seo_url(taxon)
            spree.nested_taxons_path(taxon.permalink)
          end

          def gem_available?(name)
            Gem::Specification.find_by_name(name)
          rescue Gem::LoadError
            false
          rescue
            Gem.available?(name)
          end

          def display_price(product_or_variant)
            product_or_variant.price_for_options(current_pricing_options)&.money&.to_html
          end

          def pretty_time(time)
            [I18n.l(time.to_date, format: :long),
              time.strftime("%l:%M %p")].join(" ")
          end

          def method_missing(method_name, *args, &block)
            if image_style = image_style_from_method_name(method_name)
              define_image_method(image_style)
              send(method_name, *args)
            else
              super
            end
          end

          def link_to_tracking(shipment, options = {})
            return unless shipment.tracking && shipment.shipping_method

            if shipment.tracking_url
              link_to(shipment.tracking, shipment.tracking_url, options)
            else
              content_tag(:span, shipment.tracking)
            end
          end

          private

          # Returns style of image or nil
          def image_style_from_method_name(method_name)
            if method_name.to_s.match(/_image$/) && style = method_name.to_s.sub(/_image$/, "")
              possible_styles = Spree::Image.attachment_definitions[:attachment][:styles]
              style if style.in? possible_styles.with_indifferent_access
            end
          end

          def create_product_image_tag(image, product, options, style)
            options.reverse_merge! alt: image.alt.blank? ? product.name : image.alt
            image_tag image.attachment.url(style), options
          end

          def define_image_method(style)
            self.class.send :define_method, "#{style}_image" do |product, *options|
              options = options.first || {}
              if product.images.empty?
                if !product.is_a?(Spree::Variant) && !product.variant_images.empty?
                  create_product_image_tag(product.variant_images.first, product, options, style)
                elsif product.is_a?(Spree::Variant) && !product.product.variant_images.empty?
                  create_product_image_tag(product.product.variant_images.first, product, options, style)
                else
                  image_tag "noimage/#{style}.png", options
                end
              else
                create_product_image_tag(product.images.first, product, options, style)
              end
            end
          end
        end
      end
      Spree::BaseHelper.include self
    end
  end
end
