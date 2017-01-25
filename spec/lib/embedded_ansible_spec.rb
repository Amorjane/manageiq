require "linux_admin"
require "awesome_spawn"

describe EmbeddedAnsible do
  before do
    ENV["APPLIANCE_ANSIBLE_DIRECTORY"] = nil
  end

  context ".available?" do
    it "returns true when installed in the default location" do
      allow(Dir).to receive(:exist?).with("/opt/ansible-installer").and_return(true)

      expect(described_class.available?).to be_truthy
    end

    it "returns true when installed in the custom location in env var" do
      ENV["APPLIANCE_ANSIBLE_DIRECTORY"] = "/tmp"
      allow(Dir).to receive(:exist?).with("/tmp").and_return(true)
      allow(Dir).to receive(:exist?).with("/opt/ansible-installer").and_return(false)

      expect(described_class.available?).to be_truthy
    end

    it "returns false when not installed" do
      allow(Dir).to receive(:exist?).with("/opt/ansible-installer").and_return(false)

      expect(described_class.available?).to be_falsey
    end
  end

  context "with services" do
    let(:nginx_service)       { double("nginx service") }
    let(:supervisord_service) { double("supervisord service") }
    let(:rabbitmq_service)    { double("rabbitmq service") }

    before do
      expect(AwesomeSpawn).to receive(:run!)
        .with("source /etc/sysconfig/ansible-tower; echo $TOWER_SERVICES")
        .and_return(double(:output => "nginx supervisord rabbitmq"))
      allow(LinuxAdmin::Service).to receive(:new).with("nginx").and_return(nginx_service)
      allow(LinuxAdmin::Service).to receive(:new).with("supervisord").and_return(supervisord_service)
      allow(LinuxAdmin::Service).to receive(:new).with("rabbitmq").and_return(rabbitmq_service)
    end

    describe ".running?" do
      it "returns true when all services are running" do
        expect(nginx_service).to receive(:running?).and_return(true)
        expect(supervisord_service).to receive(:running?).and_return(true)
        expect(rabbitmq_service).to receive(:running?).and_return(true)

        expect(described_class.running?).to be true
      end

      it "returns false when a service is not running" do
        expect(nginx_service).to receive(:running?).and_return(true)
        expect(supervisord_service).to receive(:running?).and_return(false)

        expect(described_class.running?).to be false
      end
    end

    describe ".stop" do
      it "stops all the services" do
        expect(nginx_service).to receive(:stop).and_return(nginx_service)
        expect(supervisord_service).to receive(:stop).and_return(supervisord_service)
        expect(rabbitmq_service).to receive(:stop).and_return(rabbitmq_service)

        expect(nginx_service).to receive(:disable).and_return(nginx_service)
        expect(supervisord_service).to receive(:disable).and_return(supervisord_service)
        expect(rabbitmq_service).to receive(:disable).and_return(rabbitmq_service)

        described_class.stop
      end
    end
  end

  context "with an miq_databases row" do
    let(:miq_database) { MiqDatabase.first }

    before do
      FactoryGirl.create(:miq_region, :region => ApplicationRecord.my_region_number)
      MiqDatabase.seed
      EvmSpecHelper.create_guid_miq_server_zone
    end

    describe ".configure" do
      before do
        expect(described_class).to receive(:configure_secret_key)
        expect(described_class).to receive(:stop)
      end

      it "generates new passwords with no passwords set" do
        expect(AwesomeSpawn).to receive(:run!) do |script_path, options|
          params                  = options[:params]
          inventory_file_contents = File.read(params[:i])

          expect(script_path).to eq("/opt/ansible-installer/setup.sh")
          expect(params[:e]).to eq("minimum_var_space=0")
          expect(params[:k]).to eq("packages,migrations,supervisor")

          new_admin_password  = miq_database.ansible_admin_password
          new_rabbit_password = miq_database.ansible_rabbitmq_password
          expect(new_admin_password).not_to be_nil
          expect(new_rabbit_password).not_to be_nil
          expect(inventory_file_contents).to include("admin_password='#{new_admin_password}'")
          expect(inventory_file_contents).to include("rabbitmq_password='#{new_rabbit_password}'")
        end

        described_class.configure
      end

      it "uses the existing passwords when they are set in the database" do
        miq_database.ansible_admin_password    = "adminpassword"
        miq_database.ansible_rabbitmq_password = "rabbitpassword"

        expect(AwesomeSpawn).to receive(:run!) do |script_path, options|
          params                  = options[:params]
          inventory_file_contents = File.read(params[:i])

          expect(script_path).to eq("/opt/ansible-installer/setup.sh")
          expect(params[:e]).to eq("minimum_var_space=0")
          expect(params[:k]).to eq("packages,migrations,supervisor")

          expect(inventory_file_contents).to include("admin_password='adminpassword'")
          expect(inventory_file_contents).to include("rabbitmq_password='rabbitpassword'")
        end

        described_class.configure
      end
    end

    describe ".start" do
      it "runs the setup script with the correct args" do
        miq_database.ansible_admin_password    = "adminpassword"
        miq_database.ansible_rabbitmq_password = "rabbitpassword"

        expect(AwesomeSpawn).to receive(:run!) do |script_path, options|
          params                  = options[:params]
          inventory_file_contents = File.read(params[:i])

          expect(script_path).to eq("/opt/ansible-installer/setup.sh")
          expect(params[:e]).to eq("minimum_var_space=0")
          expect(params[:k]).to eq("packages,migrations")

          expect(inventory_file_contents).to include("admin_password='adminpassword'")
          expect(inventory_file_contents).to include("rabbitmq_password='rabbitpassword'")
        end

        described_class.start
      end
    end

    describe ".configure_secret_key (private)" do
      let(:key_file) { Tempfile.new("SECRET_KEY") }

      before do
        stub_const("EmbeddedAnsible::SECRET_KEY_FILE", key_file.path)
      end

      after do
        key_file.unlink
      end

      it "sets a new key when there is no key in the database" do
        expect(miq_database.ansible_secret_key).to be_nil
        described_class.send(:configure_secret_key)
        miq_database.reload
        expect(miq_database.ansible_secret_key).to match(/\h+/)
        expect(miq_database.ansible_secret_key).to eq(File.read(key_file.path))
      end

      it "writes the key when a key is in the database" do
        miq_database.ansible_secret_key = "supasecret"
        expect(miq_database).not_to receive(:ansible_secret_key=)
        described_class.send(:configure_secret_key)
        expect(File.read(key_file.path)).to eq("supasecret")
      end
    end
  end
end
