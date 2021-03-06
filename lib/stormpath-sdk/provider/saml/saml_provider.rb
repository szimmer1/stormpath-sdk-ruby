#
# Copyright 2016 Stormpath, Inc.
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
module Stormpath
  module Provider
    class SamlProvider < Stormpath::Provider::Provider
      prop_reader :provider_id, :sso_login_url, :sso_logout_url,
                  :encoded_x509_signing_cert, :request_signature_algorithm

      has_one :attribute_statement_mapping_rules
      has_one :service_provider_metadata, class_name: :samlServiceProviderMetadata
    end
  end
end
