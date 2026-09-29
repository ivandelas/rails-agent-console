# frozen_string_literal: true

require "active_record"
require "logger"

ActiveRecord::Base.logger = Logger.new(IO::NULL)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :customers, force: true do |t|
    t.string :name, null: false
    t.string :country
    t.string :plan
    t.timestamps
  end

  create_table :invoices, force: true do |t|
    t.references :customer, null: false
    t.decimal :amount, precision: 10, scale: 2
    t.date :due_date
    t.datetime :paid_at
    t.string :status
    t.timestamps
  end

  create_table :support_tickets, force: true do |t|
    t.references :customer, null: false
    t.string :subject
    t.datetime :resolved_at
    t.timestamps
  end

  create_table :page_views, force: true do |t|
    t.references :customer
    t.string :path
    t.timestamps
  end
end

class Customer < ActiveRecord::Base
  has_many :invoices, dependent: :destroy
  has_many :support_tickets, dependent: :destroy
end

class Invoice < ActiveRecord::Base
  belongs_to :customer
end

class SupportTicket < ActiveRecord::Base
  belongs_to :customer
end

class PageView < ActiveRecord::Base
  belongs_to :customer, optional: true
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class LegacyThing < ActiveRecord::Base
  self.table_name = "table_that_does_not_exist"
end

module ActiveStorage
  class Attachment < ActiveRecord::Base
    self.table_name = "customers"
  end
end

module TestApp
  COUNTRIES = { "Acme Corp" => "HR", "Tesla GmbH" => "DE", "Zagreb Analytics" => "HR" }.freeze

  class << self
    def reseed!
      Invoice.delete_all
      SupportTicket.delete_all
      PageView.delete_all
      Customer.delete_all

      acme = customer("Acme Corp", plan: "enterprise", created_at: 3.days.ago)
      tesla = customer("Tesla GmbH", plan: "free", created_at: 40.days.ago)

      Invoice.create!(customer: acme, amount: 1200, status: "paid", paid_at: 1.day.ago, due_date: Date.today)
      Invoice.create!(customer: acme, amount: 800, status: "unpaid", due_date: 5.days.from_now)
      Invoice.create!(customer: tesla, amount: 500, status: "unpaid", due_date: 2.days.ago)
      SupportTicket.create!(customer: acme, subject: "Cannot log in")
      PageView.create!(customer: acme, path: "/pricing")
      PageView.create!(customer: tesla, path: "/docs")
    end

    private

    def customer(name, plan:, created_at:)
      Customer.create!(name: name, country: COUNTRIES.fetch(name, "HR"), plan: plan, created_at: created_at)
    end
  end
end
