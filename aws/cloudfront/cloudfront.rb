require_relative '../../deployment'
require 'digest'
require 'aws-sdk'

# Cloudfront-specific configuration.
CDO.cloudfront = {
  pegasus: {
    aliases: [CDO.canonical_hostname('code.org')],
    origin: CDO.origin_hostname || raise('CDO.origin_hostname required'),
    # IAM server certificate name
    ssl_cert: 'codeorg-cloudfront',
    log: {
      bucket: 'cdo-logs',
      prefix: "#{ENV['RACK_ENV']}-pegasus-cdn"
    }
  },
  dashboard: {
    aliases: [CDO.canonical_hostname('studio.code.org')],
    origin: CDO.origin_hostname || raise('CDO.origin_hostname required'),
    ssl_cert: 'codeorg-cloudfront',
    log: {
      bucket: 'cdo-logs',
      prefix: "#{ENV['RACK_ENV']}-dashboard-cdn"
    }
  }
}

ALL_COOKIES = %w(
  _learn_session
  hour_of_code
  language_
  storage
  storage_id
)

STATIC_ASSETS = {
  # For static-asset extensions, don't forward any cookies and strip language headers.
  path: %w(cur pdf png gif jpeg jpg ico mp3 swf css js).map{|ext| "*.#{ext}"},
  headers: [],
  cookies: 'none'
}

# Host header is needed for Varnish to delegate to pegasus/dashboard depending on the host.
# Accept-Language header is needed to cache language-specific pages.
ALL_HEADERS = %w(Host Accept-Language)
LANGUAGE_COOKIE = %w(language_)

# HTTP-cache configuration that can be applied both to CDN (e.g. Cloudfront) and origin-local HTTP cache (e.g. Varnish).
# Whenever possible, the application should deliver correct HTTP response headers to direct cache behaviors.
# This hash provides extra application-specific configuration for whitelisting specific request headers and
# cookies based on the request path.
CDO.http_cache = {
  pegasus: {
    behaviors: [
      STATIC_ASSETS,
      # Dashboard-based API paths in Pegasus are session-specific, whitelist all session cookies and language headers.
      {
        path: %w(
          v2/*
          v3/*
          private*
        ) +
        # Todo: Collapse these paths into /private to simplify Pegasus caching config
        %w(
          create-company-profile*
          edit-company-profile*
          teacher-dashboard*
          manage-professional-development-workshops*
          professional-development-workshop-surveys*
          ops-dashboard*
          poste*
        ),
        headers: ALL_HEADERS,
        cookies: ALL_COOKIES
      },
      {
        path: 'dashboardapi/*',
        proxy: 'studio.code.org',
        headers: ALL_HEADERS,
        cookies: ALL_COOKIES
      }
    ],
    # Default Pegasus paths are cached but language-specific, whitelist only language cookies/headers.
    default: {
      headers: ALL_HEADERS,
      cookies: LANGUAGE_COOKIE
    }
  },
  dashboard: {
    behaviors: [
      STATIC_ASSETS,
      {
        path: 'v2/*',
        proxy: 'code.org/v2',
        headers: ALL_HEADERS,
        cookies: ALL_COOKIES
      }
    ],
    # Default Dashboard paths are session-specific, whitelist all session cookies and language headers.
    default: {
      headers: ALL_HEADERS,
      cookies: ALL_COOKIES
    }
  }
}

# Returns a CloudFront DistributionConfig Hash compatible with the AWS SDK for Ruby v2.
# Syntax reference: http://docs.aws.amazon.com/sdkforruby/api/Aws/CloudFront/Types/DistributionConfig.html
def cloudfront_config(cloudfront, config, reference = nil)
  behaviors = config[:behaviors].map do |behavior|
    if behavior[:path].is_a? Array
      behavior[:path].map do |path|
        cache_behavior behavior, path
      end
    else
      cache_behavior behavior, behavior[:path]
    end
  end.flatten

  ssl_cert = cloudfront[:ssl_cert] &&
  {
    aliases: {
      quantity: cloudfront[:aliases].length, # required
      items: cloudfront[:aliases].empty? ? nil : cloudfront[:aliases],
    },
    default_root_object: '',
    origins: {# required
      quantity: 1, # required
      items: [
        {
          id: 'cdo', # required
          domain_name: cloudfront[:origin], # required
          origin_path: '',
          custom_origin_config: {
            http_port: 80, # required
            https_port: 443, # required
            origin_protocol_policy: 'match-viewer', # required, accepts http-only, match-viewer
          },
        },
      ],
    },
    default_cache_behavior: cache_behavior(config[:default]),
    cache_behaviors: {
      quantity: behaviors.length, # required
      items: behaviors.empty? ? nil : behaviors,
    },
    custom_error_responses: {
      quantity: 0 # required
    },
    comment: '', # required
    logging: {
      enabled: !!cloudfront[:log], # required
      include_cookies: false, # required
      bucket: cloudfront[:log] && "#{cloudfront[:log][:bucket]}.s3.amazonaws.com", # required
      prefix: cloudfront[:log] && cloudfront[:log][:prefix], # required
    },
    price_class: 'PriceClass_All', # accepts PriceClass_100, PriceClass_200, PriceClass_All
    enabled: true, # required
    viewer_certificate: cloudfront[:ssl_cert] ? {
      # Lookup IAM Certificate ID from server certificate name
      iam_certificate_id: Aws::IAM::Client.new
        .get_server_certificate(server_certificate_name: cloudfront[:ssl_cert])
        .server_certificate.server_certificate_metadata.server_certificate_id,
      ssl_support_method: 'sni-only', # accepts sni-only, vip
      minimum_protocol_version: 'TLSv1', # accepts SSLv3, TLSv1
      cloud_front_default_certificate: false
    } : {
      cloud_front_default_certificate: true,
      minimum_protocol_version: 'TLSv1' # accepts SSLv3, TLSv1
    },
    restrictions: {
      geo_restriction: {# required
        restriction_type: 'none', # required, accepts blacklist, whitelist, none
        quantity: 0 # required
      },
    },
  }.tap do |cf|
    cf[:caller_reference] = reference || Digest::MD5.hexdigest(Marshal.dump(config)) # required
  end
end

# `config` contains `headers` and `cookies` whitelists.
def cache_behavior(config, path=nil)
  behavior = {# required
    target_origin_id: 'cdo', # required
    forwarded_values: {# required
      query_string: true, # required
      cookies: config[:cookies].is_a?(Array) ? {# required
        forward: 'whitelist', # required, accepts none, whitelist, all
        whitelisted_names: {
          quantity: config[:cookies].length, # required
          items: (config[:cookies].empty? ? nil : config[:cookies]),
        }
      } : {
        forward: config[:cookies]
      },
      headers: {
        quantity: config[:headers].length, # required
        items: config[:headers].empty? ? nil : config[:headers],
      },
    },
    trusted_signers: {# required
      enabled: false, # required
      quantity: 0
    },
    viewer_protocol_policy: 'redirect-to-https', # required, accepts allow-all, https-only, redirect-to-https
    min_ttl: 0, # required
    allowed_methods: {
      quantity: 7, # required
      items: %w(HEAD DELETE POST GET OPTIONS PUT PATCH), # required, accepts GET, HEAD, POST, PUT, PATCH, OPTIONS, DELETE
      cached_methods: {
        quantity: 3, # required
        items: %w(HEAD GET OPTIONS), # required, accepts GET, HEAD, POST, PUT, PATCH, OPTIONS, DELETE
      },
    },
    smooth_streaming: false,
    default_ttl: 0,
    max_ttl: 31536000, # =1 year
  }
  behavior[:path_pattern] = path if path
  behavior
end
