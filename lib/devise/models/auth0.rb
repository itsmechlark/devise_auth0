# frozen_string_literal: true

require "mail"
require "devise/hooks/auth0"

module Devise
  module Models
    module Auth0
      extend ActiveSupport::Concern

      included do
        validates :uid, allow_blank: true, uniqueness: { scope: :provider, message: "should happen once per provider" }
        with_options if: -> { respond_to?(:email) } do
          validates :email, uniqueness: true
          validate :email_domain_allowed, :email_domain_disallowed
        end
      end

      class << self
        def required_fields(klass)
          []
        end
      end

      def email_domain_allowed
        return if self.class.auth0_config.email_domains_allowlist.empty?

        m = Mail::Address.new(email)
        return if m.domain.nil?

        unless self.class.auth0_config.email_domains_allowlist.include?(m.domain)
          errors.add(:email, :not_allowed)
        end
      end

      def email_domain_disallowed
        return if self.class.auth0_config.email_domains_blocklist.empty?

        m = Mail::Address.new(email)
        return if m.domain.nil?

        if self.class.auth0_config.email_domains_blocklist.include?(m.domain)
          errors.add(:email, :not_allowed)
        end
      end

      def can?(action, resource_class = nil)
        scope = [action]
        if resource_class.is_a?(String)
          scope << resource_class
        elsif resource_class
          resource_name = resource_class.name.underscore.split("/")
          resource_name[-1] = resource_name[-1].pluralize
          scope << resource_name.join("/")
        end
        auth0_scopes.include?(scope.join(":"))
      end

      # Convenience method which works the same as "can?" but returns the opposite value.
      #
      #   cannot? :destroy, @project
      #
      def cannot?(*args)
        !can?(*args)
      end

      def auth0_scopes=(scopes)
        ::Devise.auth0.cache.write(
          "devise-auth0/#{auth0_id}/scopes",
          scopes,
          expires_in: ::Devise.auth0.cache_expires_in,
        )
      end

      def auth0_scopes
        ::Devise.auth0.cache.fetch("devise-auth0/#{auth0_id}/scopes", expires_in: ::Devise.auth0.cache_expires_in) do
          if bot?
            self.class.auth0_client.client_grants(
              client_id: uid,
              audience: self.class.auth0_config.aud,
            ).first.try(:[], "scope")
          else
            user = self.class.auth0_client.users_by_email(email).find do |u|
              u["identities"].any? { |i| i["user_id"] == uid }
            end
            return [] if user.nil?

            permissions = []
            page = 0
            loop do
              response_data = self.class.auth0_client
                .get_user_permissions(
                  user["user_id"],
                  { page: page, per_page: 100, include_totals: true },
                )

              response_data["permissions"].select do |permission|
                self.class.auth0_config.aud.include?(permission["resource_server_identifier"])
              end.each do |permission|
                permissions << permission["permission_name"]
              end

              break if response_data["start"] / 100 == response_data["total"] / 100

              page += 1
            end
            permissions
          end
        end
      end

      def auth0_id
        "#{provider}|#{uid}"
      end

      def after_auth0_token_created(token)
      end

      def after_auth0_token(token)
        set_auth_id(token.provider, token.uid)
      end

      def after_auth0_omniauth_created(auth)
      end

      def after_auth0_omniauth(auth)
        set_auth_id(auth.provider, auth.uid)
      end

      private

      def set_auth_id(provider, uid)
        return if self.provider == provider && self.uid == uid

        self.provider = provider
        self.uid = uid.include?("|") ? uid.split("|").last : uid
        save
      end

      module ClassMethods
        Devise::Models.config(self, :auth0_options)

        def from_auth0_token(token)
          user = where(
            auth0_where_conditions(
              provider: token.provider,
              uid: token.uid,
              email: token.user["email"],
            ),
          ).first_or_create do |user|
            user.provider = token.provider
            user.uid = token.uid
            user.email = token.user["email"] if user.respond_to?(:email=)
            user.password = Devise.friendly_token[0, 20] if user.respond_to?(:password=)
            user.bot = token.bot? if user.respond_to?(:bot=)
            user.after_auth0_token_created(token)
          end
          user.auth0_scopes = token.scopes.dup.concat(token.permissions).uniq
          user.after_auth0_token(token)
          user
        end

        def parse_auth0_token(token)
          ::Devise::Auth0::Token.parse(token, self)
        end

        def from_auth0_omniauth(auth)
          return unless auth0_config.omniauth

          uid = auth.uid.include?("|") ? auth.uid.split("|").last : auth.uid
          user = where(
            auth0_where_conditions(
              provider: auth.provider,
              uid: uid,
              email: auth.info.email,
            ),
          ).first_or_create do |user|
            user.provider = auth.provider
            user.uid = uid
            user.email = auth.info.email if user.respond_to?(:email=)
            user.password = Devise.friendly_token[0, 20] if user.respond_to?(:password=)
            user.after_auth0_omniauth_created(auth)
          end
          user.after_auth0_omniauth(auth)
          user
        end

        def auth0_where_conditions(provider:, uid:, email: nil)
          sql = arel_table[:provider].eq(provider).and(arel_table[:uid].eq(uid))
          sql = sql.or(arel_table[:email].eq(email)) if email && column_names.include?("email")
          sql
        end

        def auth0_config
          return @auth0_config unless @auth0_config.nil?

          @auth0_config ||= ::Devise.auth0.pristine
          @auth0_config.update(::Devise.auth0.values)
          @auth0_config.update(auth0_options) if defined?(@auth0_options)
          @auth0_config.finalize!
          @auth0_config
        end

        def auth0_client
          @auth0_client ||= ::Devise::Auth0::Client.new(auth0_config)
        end
      end
    end
  end
end
