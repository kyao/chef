#
# Author:: Daniel DeLeo (<dan@getchef.com>)
# Copyright:: Copyright (c) 2014 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'chef/config'

class Chef
  class Knife
    class SslCheck < Chef::Knife

      deps do
        require 'pp'
        require 'socket'
        require 'uri'
        require 'chef/http/ssl_policies'
        require 'openssl'
      end

      banner "knife ssl check [URL] (options)"

      def initialize(*args)
        @host = nil
        @verify_peer_socket = nil
        @ssl_policy = HTTP::DefaultSSLPolicy
        super
      end

      def uri
        @uri ||= begin
          Chef::Log.debug("Checking SSL cert on #{given_uri}")
          URI.parse(given_uri)
        end
      end

      def given_uri
        (name_args[0] or Chef::Config.chef_server_url)
      end

      def host
        uri.host
      end

      def port
        uri.port
      end

      def validate_uri
        unless host && port
          invalid_uri!
        end
      rescue URI::Error
        invalid_uri!
      end

      def invalid_uri!
        ui.error("Given URI: `#{given_uri}' is invalid")
        show_usage
        exit 1
      end


      def verify_peer_socket
        @verify_peer_socket ||= begin
          tcp_connection = TCPSocket.new(host, port)
          OpenSSL::SSL::SSLSocket.new(tcp_connection, verify_peer_ssl_context)
        end
      end

      def verify_peer_ssl_context
        @verify_peer_ssl_context ||= begin
          verify_peer_context = OpenSSL::SSL::SSLContext.new
          @ssl_policy.apply_to(verify_peer_context)
          verify_peer_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          verify_peer_context
        end
      end

      def noverify_socket
        @noverify_socket ||= begin
          tcp_connection = TCPSocket.new(host, port)
          OpenSSL::SSL::SSLSocket.new(tcp_connection, noverify_peer_ssl_context)
        end
      end

      def noverify_peer_ssl_context
        @noverify_peer_ssl_context ||= begin
          noverify_peer_context = OpenSSL::SSL::SSLContext.new
          @ssl_policy.apply_to(noverify_peer_context)
          noverify_peer_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
          noverify_peer_context
        end
      end

      def verify_X509
        cert_debug_msg = ""
        trusted_certificates.each do |cert_name|
          message = check_X509_certificate(cert_name)
          unless message.nil?
            cert_debug_msg << File.expand_path(cert_name) + ": " + message + "\n"
          end
        end

        unless cert_debug_msg.empty?
          debug_invalid_X509(cert_debug_msg)
        end

        true # Maybe the bad certs won't hurt...
      end

      def verify_cert
        ui.msg("Connecting to host #{host}:#{port}")
        verify_peer_socket.connect
        true
      rescue OpenSSL::SSL::SSLError => e
        ui.error "The SSL certificate of #{host} could not be verified"
        Chef::Log.debug e.message
        debug_invalid_cert
        false
      end

      def verify_cert_host
        verify_peer_socket.post_connection_check(host)
        true
      rescue OpenSSL::SSL::SSLError => e
        ui.error "The SSL cert is signed by a trusted authority but is not valid for the given hostname"
        Chef::Log.debug(e)
        debug_invalid_host
        false
      end

      def debug_invalid_X509(cert_debug_msg)
        ui.msg("\n#{ui.color("Configuration Info:", :bold)}\n\n")
        debug_ssl_settings
        debug_chef_ssl_config

        ui.warn(<<-BAD_CERTS)
There are invalid certificates in your trusted_certs_dir.
OpenSSL will not use the following certificates when verifying SSL connections:

#{cert_debug_msg}

#{ui.color("TO FIX THESE WARNINGS:", :bold)}

We are working on documentation for resolving common issues uncovered here.

* If the certificate is generated by the server, you may try redownloading the
server's certificate. By default, the certificate is stored in the following
location on the host where your chef-server runs:

  /var/opt/chef-server/nginx/ca/SERVER_HOSTNAME.crt

Copy that file to your trusted_certs_dir (currently: #{configuration.trusted_certs_dir})
using SSH/SCP or some other secure method, then re-run this command to confirm
that the server's certificate is now trusted.

BAD_CERTS
        # @TODO: ^ needs URL once documentation is posted.
      end

      def debug_invalid_cert
        noverify_socket.connect
        issuer_info = noverify_socket.peer_cert.issuer
        ui.msg("Certificate issuer data: #{issuer_info}")

        ui.msg("\n#{ui.color("Configuration Info:", :bold)}\n\n")
        debug_ssl_settings
        debug_chef_ssl_config

        ui.err(<<-ADVICE)

#{ui.color("TO FIX THIS ERROR:", :bold)}

If the server you are connecting to uses a self-signed certificate, you must
configure chef to trust that server's certificate.

By default, the certificate is stored in the following location on the host
where your chef-server runs:

  /var/opt/chef-server/nginx/ca/SERVER_HOSTNAME.crt

Copy that file to your trusted_certs_dir (currently: #{configuration.trusted_certs_dir})
using SSH/SCP or some other secure method, then re-run this command to confirm
that the server's certificate is now trusted.

ADVICE
      end

      def debug_invalid_host
        noverify_socket.connect
        subject = noverify_socket.peer_cert.subject
        cn_field_tuple = subject.to_a.find {|field| field[0] == "CN" }
        cn = cn_field_tuple[1]

        ui.error("You are attempting to connect to:   '#{host}'")
        ui.error("The server's certificate belongs to '#{cn}'")
        ui.err(<<-ADVICE)

#{ui.color("TO FIX THIS ERROR:", :bold)}

The solution for this issue depends on your networking configuration. If you
are able to connect to this server using the hostname #{cn}
instead of #{host}, then you can resolve this issue by updating chef_server_url
in your configuration file.

If you are not able to connect to the server using the hostname #{cn}
you will have to update the certificate on the server to use the correct hostname.
ADVICE
      end

      def debug_ssl_settings
        ui.err "OpenSSL Configuration:"
        ui.err "* Version: #{OpenSSL::OPENSSL_VERSION}"
        ui.err "* Certificate file: #{OpenSSL::X509::DEFAULT_CERT_FILE}"
        ui.err "* Certificate directory: #{OpenSSL::X509::DEFAULT_CERT_DIR}"
      end

      def debug_chef_ssl_config
        ui.err "Chef SSL Configuration:"
        ui.err "* ssl_ca_path: #{configuration.ssl_ca_path.inspect}"
        ui.err "* ssl_ca_file: #{configuration.ssl_ca_file.inspect}"
        ui.err "* trusted_certs_dir: #{configuration.trusted_certs_dir.inspect}"
      end

      def configuration
        Chef::Config
      end

      def run
        validate_uri
        if verify_X509 && verify_cert && verify_cert_host
          ui.msg "Successfully verified certificates from `#{host}'"
        else
          exit 1
        end
      end

      private
      def trusted_certificates
        if configuration.trusted_certs_dir && Dir.exist?(configuration.trusted_certs_dir)
          Dir.glob(File.join(configuration.trusted_certs_dir, "*.{crt,pem}"))
        else
          []
        end
      end

      def check_X509_certificate(cert_file)
        store = OpenSSL::X509::Store.new
        cert = OpenSSL::X509::Certificate.new(IO.read(File.expand_path(cert_file)))
        begin
          store.add_cert(cert)
          # test if the store can verify the cert we just added
          unless store.verify(cert) # true if verified, false if not
            return store.error_string
          end
        rescue OpenSSL::X509::StoreError => e
          return e.message
        end
        return nil
      end
    end
  end
end
