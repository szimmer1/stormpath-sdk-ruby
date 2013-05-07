#
# Copyright 2012 Stormpath, Inc.
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
class Stormpath::Resource::Collection
  include Enumerable

  attr_reader :href, :client, :item_class

  def initialize(href, item_class, client)
    @client = client
    @href = href
    @item_class = item_class
  end

  def data_store
    client.data_store
  end

  def each(&block)
    offset = 0
    while true
      page = CollectionPage.new "#{href}?offset=#{offset}", client
      page.item_type = item_class
      items = page.items
      items.each(&block)
      break if items.length < page.limit
      offset += page.limit
    end
  end

  def create properties_or_resource
    resource = case properties_or_resource
               when Stormpath::Resource::Base
                 properties_or_resource
               else
                 item_class.new properties_or_resource, client
               end
    data_store.create href, resource, item_class
  end

  def get id_or_href
    item_href = if id_or_href.index '/'
                  id_or_href
                else
                  "#{href}/#{id_or_href}"
                end
    data_store.get_resource item_href, item_class
  end

  private

  class CollectionPage < Stormpath::Resource::Base
    ITEMS = 'items'

    prop_accessor :offset, :limit

    attr_accessor :item_type

    def items
      to_resource_array get_property ITEMS
    end

    def to_resource properties
      data_store.instantiate item_type, properties
    end

    def to_resource_array vals
      Array.new.tap do |items|
        if vals.is_a? Array
          vals.each do |val|
            resource = to_resource val
            items << resource
          end
        end
      end
    end
  end
end
