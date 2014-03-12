require 'spec_helper'

describe Stormpath::Resource::CustomData, :vcr do
  let(:directory) { test_api_client.directories.create name: 'test_directory' }

  after do
    directory.delete if directory
  end

  context 'account' do
    let(:custom_data_storage) do
      directory.accounts.create username: "jlpicard",
         email: "capt@enterprise.com",
         givenName: "Jean-Luc",
         surname: "Picard",
         password: "uGhd%a8Kl!"
    end
    
    let(:reloaded_custom_data_storage) do
      test_api_client.accounts.get custom_data_storage.href
    end

    let(:reloaded_custom_data_storage_2) do
      test_api_client.accounts.get custom_data_storage.href
    end

    after do
      custom_data_storage.delete if custom_data_storage
    end

    it_behaves_like 'custom_data_storage'
  end

  context 'group' do
    let(:custom_data_storage) do
      directory.groups.create name: 'test_group'
    end

    let(:reloaded_custom_data_storage) do
      test_api_client.groups.get custom_data_storage.href
    end

    let(:reloaded_custom_data_storage_2) do
      test_api_client.groups.get custom_data_storage.href
    end

    after do
      custom_data_storage.delete if custom_data_storage
    end

    it_behaves_like 'custom_data_storage'
  end
end
