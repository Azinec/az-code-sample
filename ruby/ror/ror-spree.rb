### app/controllers/bonuses_controller.rb

# frozen_string_literal: true

class BonusesController < Spree::BaseController
  def index
    @bonuses = Spree::Bonus.active
  end

  def show
    @bonus = Spree::Bonus.active.find(params[:id])
  end
end


### app/models/spree/bonus.rb

module Spree
  class Bonus < Spree::Base
    self.table_name = :bonuses

    extend FriendlyId
    friendly_id :slug_candidates, use: :slugged

    acts_as_paranoid

    has_many :images, -> { order(:position) }, as: :viewable, dependent: :destroy, class_name: 'Spree::Image'

    after_destroy :punch_slug
    after_restore :update_slug_history

    before_validation :normalize_slug, on: :update

    validates :name, :points, presence: true
    validates :slug, presence: true, uniqueness: { allow_blank: true }

    private

    def available?
      !(available_on.nil? || available_on.future?) && !deleted? && !discontinued?
    end

    def slug_candidates
      [
        :name,
        [:name, :id] # or smth
      ]
    end

    def normalize_slug
      self.slug = normalize_friendly_id(slug)
    end

    def punch_slug
      update_column(:slug, "#{Time.current.to_i}_#{slug}"[0..254]) unless frozen?
    end

    def update_slug_history
      save!
    end

    def deleted?
      !!deleted_at
    end
  end
end


### app/models/spree/spree_order_decorator.rb

module Spree
  Order.class_eval do
    after_update :calculate_user_bonus_points

    def total_bonus_points
      line_items.sum { |le| le.product.bonus_points * le.quantity }
    end

    def calculate_user_bonus_points
      user.available_bonus_points += total_bonus_points
      user.save
    end
  end
end


### app/models/spree/spree_product_decorator.rb

module Spree
  Product.class_eval do
    validates :bonus_points, numericality: { greater_than: 0, allow_blank: true }
  end
end


### app/overrides/*

Deface::Override.new(
  virtual_path: 'spree/products/_product',
  name: 'bonuses_display_bonus_points',
  insert_after: '[itemprop="price"]',
  partial: 'spree/bonuses/bonus_points_index'
)

Deface::Override.new(
  virtual_path: 'spree/products/_cart_form',
  name: 'product_show_display_bonus_points',
  insert_top: '[data-hook="product_price"]',
  partial: 'spree/bonuses/bonus_points'
)

Deface::Override.new(
  virtual_path: 'spree/users/show',
  name: 'admin_product_edit_display_bonus_points',
  insert_bottom: '[id="user-info"]',
  partial: 'spree/bonuses/account_summary_show'
)

Deface::Override.new(
  virtual_path: 'spree/orders/_form',
  name: 'order_form_total_bonus_points',
  replace: '[data-hook="orders_cart_total"]',
  partial: 'spree/bonuses/order_form_total_bonus_poins'
)

Deface::Override.new(
  virtual_path: 'spree/admin/products/_form',
  name: 'admin_product_edit_display_bonus_points',
  insert_after: '[data-hook="admin_product_form_cost_price"]',
  partial: 'spree/bonuses/admin_bonus_on_product_form'
)

Deface::Override.new(
  virtual_path: 'spree/orders/_line_item',
  name: 'line_item_display_bonus_points',
  replace: '[data-hook="cart_item_price"]',
  partial: 'spree/bonuses/bonus_on_cart_item'
)


### app/db/migrate/*

class AddBonusPointsToSpreeProducts < ActiveRecord::Migration[5.1]
  def change
    add_column :spree_products, :bonus_points, :integer, default: 0, null: false
  end
end

#

class AddAvailableBonusPointsToUser < ActiveRecord::Migration[5.1]
  def change
    add_column :spree_users, :available_bonus_points, :integer, default: 0, null:false
  end
end

#

class CreateBonuses < ActiveRecord::Migration[5.1]
  def change
    create_table :bonuses do |t|
      t.string     :name, default: '', null: false
      t.text       :description
      t.integer    :points, default: 0, null: false
      t.datetime   :available_on
      t.datetime   :deleted_at
      t.string     :slug
      t.integer    :count_on_hand, default: 0,  null: false
      # t.string     :meta_description
      # t.string     :meta_keywords
      t.timestamps null: false
    end

    add_index :bonuses, [:available_on], name: 'index_bonuses_on_available_on'
    add_index :bonuses, [:deleted_at],   name: 'index_bonuses_on_deleted_at'
    add_index :bonuses, [:name],         name: 'index_bonuses_on_name'
    add_index :bonuses, [:slug],         name: 'index_bonuses_on_slug', unique: true
  end
end


### app/views/spree/bonuses/_account_summary_show.html.erb

<br />
<dt>Available Bonus Points</dt>
<dd>
  <%= spree_current_user.available_bonus_points %>
</dd>


### app/views/spree/bonuses/_admin_bonus_on_product_form.html.erb

<div data-hook="admin_product_form_bonus_points" class="alpha two columns">
  <%= f.field_container :bonus_points, class: ['form-group'] do %>
    <%= f.label :bonus_points, 'Bonus Points' %>
    <%= f.text_field :bonus_points, value: @product.bonus_points, class: 'form-control' %>
    <%= f.error_message_on :bonus_points %>
  <% end %>
</div>


### app/views/spree/bonuses/_bonus.html.erb

<div id="bonus_<%= bonus.id %>" class="col-md-3 col-sm-6 col-xs-6 bonus-list-item" data-hook="bonus_list_item">
  <div class="panel panel-default">
    <div class="panel-body text-center bonus-body">
      <%= link_to '#', itemprop: "url" do %>
        <%= small_image(bonus, itemprop: "image") %><br/>
        <%= content_tag(:span, truncate(bonus.name, length: 50), class: 'info', itemprop: "name", title: bonus.name) %>
      <% end %>
      <br/>
    </div>
    <div class="panel-footer text-center">
      <span itemprop="offers" itemscope itemtype="https://schema.org/Offer">
        <span class="points lead" itemprop="bonusPrice" content="<%= bonus.points %>">
          bonus.points
        </span>
      </span>
    </div>
  </div>
</div>


### app/views/spree/bonuses/_bonus_on_cart_item.html.erb

<td class="lead text-primary cart-item-price" data-hook="cart_item_price">
  <%= line_item.single_money.to_html %>
  <% if line_item&.product&.bonus_points > 0 %>
    <div class="text-center h6"><%= line_item.product.bonus_points %>bp</div>
  <% end %>
</td>


### app/views/spree/bonuses/_bonus_points.html.erb

<% if @product.bonus_points > 0 %>
  <div id="product-price">
    <h6 class="product-section-title">Bonus Points</h6>
    <div>
      <span class="lead" itemprop="bonusPoints" content="<%= @product.bonus_points %>">
        <%= @product.bonus_points %>
      </span>
    </div>
  </div>
<% end %>


>###  app/views/spree/bonuses/_bonus_points_index.html.erb

<% if product.bonus_points > 0 %>
  <span class="lead">-</span>
  <span class="lead h1"><%= product.bonus_points %><small>bp</small></span>
<% end %>


>### app/views/spree/bonuses/_order_form_total_bonus_poins.html.erb

<tr class="warning cart-total">
  <td></td>
  <td colspan="2" align="right"><h5>Total Bonus Points:</h5></td>
  <td class="lead" colspan><%= order_form.object.total_bonus_points %></td>
  <td align='right'><h5><%= Spree.t(:total) %></h5></td>
  <td class="lead" colspan><%= order_form.object.display_total %></td>
  <td></td>
</tr>


### app/views/spree/shared/_bonuses.html.erb

<% content_for :head do %>
  <% if @bonuses.respond_to?(:total_pages) %>
    <%= rel_next_prev_link_tags @bonuses %>
  <% end %>
<% end %>

<% if @bonuses.any? %>
  <div id="bonuses" class="row" data-hook>
    <%= render partial: 'spree/bonuses/bonus', collection: @bonuses %>
  </div>
<% end %>

<% if @bonuses.respond_to?(:total_pages) %>
  <%= paginate @bonuses, theme: 'twitter-bootstrap-3' %>
<% end %>
