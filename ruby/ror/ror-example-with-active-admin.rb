### Example of RoR model named Contest

# frozen_string_literal: true

class Contest < ApplicationRecord
  include AppName::HasUploadedImage
  include AppName::HasEditorium

  has_many :contest_votes, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :first_day, :last_day, presence: true

  validates :credits_by_shipment, :credits_by_vote, :credits_by_unit,
    presence: true, numericality: { greater_than_or_equal_to: 0 }

  validate :list_users_exist?
  validate :correct_start_end_order?
  validate :card_image_presence_if_needed?

  translates :name, :url, :checkbox_title_1, :checkbox_title_2, :checkbox_title_3,
    :timeline, :recycling_program, :how_it_works_section_simple, :prizes_section_simple,
    :short_description, versioning: :paper_trail

  has_unique_url from: :name

  has_image :card_image, allow_empty: true
  has_image :header_image, allow_empty: true

  has_editorium :intro_section
  has_editorium :pre_start_section
  has_editorium :vote_section
  has_editorium :contest_end_section
  has_editorium :how_it_works_section
  has_editorium :prizes_section
  has_editorium :official_results_section

  after_commit :invalidate_leaderboard

  # This module includes extended habtm with tracking the changes with the associations
  include AppName::PaperTrailHabtm

  versioned_habtm :brigades
  versioned_habtm :regions
  versioned_habtm :select_options,
    conditions: ->(_val = nil) do
      ['select_options_category_id = ?',
       SelectOptionsCategory.find_by(name: 'organization_types').id]
    end

  scope :list_visible_for_brigade, ->(type) {
    send(type, Time.current.to_date)
      .visible
      .with_translations(I18n.locale.to_s)
      .order('last_day asc')
  }
  scope :list_visible, ->(type) {
    list_visible_for_brigade(type)
      .joins(:brigades)
      .merge(Brigade.public_facing)
      .distinct
  }
  scope :active, ->(date) {
    where('first_day <= ? and last_day >= ?', date, date)
  }
  scope :finished, ->(date) {
    where('last_day < ?', date)
  }
  scope :upcoming, ->(date) {
    where('first_day > ?', date)
  }
  scope :visible, -> {
    where(hide_card: false)
  }

  def interval_in_time_zone(offset = 0)
    first_day.in_time_zone..last_day.in_time_zone + offset
  end

  def card_image_presence_if_needed?
    unless image_usages.map(&:imageable_field).include?('card_image') || hide_card
      errors.add(:card_image, I18n.t('activerecord.errors.messages.blank'))
    end
  end

  def list_users_exist?
    return if users_list_ids.blank?

    wrong_ids = list_ids - User.where(id: list_ids).map { |user| user.id.to_s }
    return if wrong_ids.empty?

    errors.add(:users_list_ids,
      "#{I18n.t('contest.attributes.user_id.missing')}: #{wrong_ids.join(', ')}")
  end

  def list_ids
    users_list_ids.delete(' ').split(',')
  end

  def blacklisted
    users_list_white ? [] : list_ids
  end

  def correct_start_end_order?
    return unless last_day && first_day && (last_day <= first_day)
    errors.add(:last_day, I18n.t('contest.attributes.last_day.numericality'))
  end

  def cache_key
    "#{Country.current.code}_contest/#{id}/#{updated_at.to_i}"
  end

  def leaderboard_cache_key
    "#{Country.current.code}_contest/#{id}/leaderboard"
  end

  def invalidate_leaderboard
    Resque.enqueue(ContestGenerateLeaderboard, id) if leaderboard_display_address
  end

  def leaderboard
    return Rails.cache.read(leaderboard_cache_key) if Rails.cache.exist?(leaderboard_cache_key)

    invalidate_leaderboard
    []
  end

  def leaderboard_calc
    calculate_ranks(leaderboard_scope.all)
  end

  def leaderboard_scope
    Profile.select(
      "*, "\
      "#{credits_by_shipment} * shipment_count + "\
      "#{credits_by_vote} * vote_count + "\
      "#{credits_by_unit} * units_count as credits"
    ).from(raw_numbers)
      .order(
        'credits desc, organization_name, city, region_code, zipcode'
      )
  end

  def raw_numbers
    contestant_list
      .select(
        [
          Profile.arel_table[:id],
          :organization_name,
          User.arel_table[:first_name],
          User.arel_table[:last_name],
          :city,
          Region.arel_table[:region_code],
          :zipcode,
          active_contest_votes
            .select('count(*)')
            .where('profile_id = profiles.id')
            .as('vote_count'),
          allowed_shipments
            .select('count(*)')
            .where('collections.profile_id = profiles.id')
            .as('shipment_count'),
          allowed_shipments
            .select('COALESCE(sum(units_collected), 0)')
            .where('collections.profile_id = profiles.id')
            .as('units_count')
        ]
      ).group(
        'profiles.id, collections.profile_id, users.first_name, users.last_name,
         profiles.organization_name, profiles.city, regions.region_code, profiles.zipcode'
      )
  end

  def participant_search(query)
    contestant_list
      .uniq
      .where(
        "
          profiles.organization_name ILIKE :query OR
          CONCAT(users.first_name, ' ', users.last_name) ILIKE :query OR
          profiles.zipcode ILIKE :query OR
          profiles.city ILIKE :query OR
          regions.region_code ILIKE :query
        ", query: "%#{query}%"
      )
      .limit(5)
  end

  def contestant_list
    allowed_profiles
      .joins('LEFT JOIN regions ON regions.id = profiles.region_ID')
      .joins(:user)
      .joins(:collections)
      .merge(allowed_collections)
  end

  def allowed_collections
    Collection.active.where(brigade_id: brigade_ids)
  end

  def calculate_ranks(lb)
    current_credits = current_rank = -1
    lb.enum_for(:each_with_index).map do |profile, index|
      if profile.credits != current_credits
        current_rank    = index + 1
        current_credits = profile.credits
      end
      OpenStruct.new(profile.serializable_hash.merge(rank: current_rank, id: profile.id))
    end
  end

  def active_contest_votes
    ContestVote.joins(:contest_email)
      .where(ContestVote.arel_table[:contest_id].eq(id))
      .where(ContestEmail.arel_table[:verified].eq(true))
      .where(contest_votes: { created_at: interval_in_time_zone(1.day) })
  end

  def allowed_profiles
    scope = Country.current.profiles.where(filter_by_list_ids)

    unless users_list_white
      if select_options.present?
        scope = scope.where(organization_type_id: select_options.pluck(:id))
      end

      if regions.present?
        scope = scope.where(region_id: regions.pluck(:id))
      end
    end

    scope.order(
      'profiles.organization_name',
      'profiles.city',
      'profiles.zipcode'
    )
  end

  def allowed_shipments
    Shipment.where(created_at: interval_in_time_zone(1.day))
      .joins(label_request: :collection)
      .merge(allowed_collections)
  end

  def filter_by_list_ids
    return unless list_ids.present?

    profile_ids = User.where(id: list_ids).map { |u| u.current_profile.id }

    if users_list_white
      Profile.arel_table[:id].in(profile_ids) # whitelist
    else
      Profile.arel_table[:id].not_in(profile_ids) # blacklist
    end
  end
end


### Contest controller

# frozen_string_literal: true

# controller to handle contests
class ContestsController < ApplicationController
  before_action :find_contest, except: [:index, :history]
  before_action :assign_date, only: [:show, :embed, :vote]
  before_action :fill_leaderboard, only: [:show, :leaderboard, :embed, :vote]
  after_action :allow_iframe, only: [:embed, :vote]

  def participants
    json = @contest.participant_search(ActiveRecord::Base.send(:sanitize_sql_like, params[:query]))

    render json: json,
           each_serializer: ContestParticipantSerializer,
           contest: @contest,
           adapter: :attributes
  end

  def index
    @contests = Contest.list_visible(:active).decorate
    @upcoming_contests = Contest.list_visible(:upcoming).decorate

    unless Contest.visible.any?
      redirect_to url_for_page('contests-and-promotions')
      return
    end
    unless (@contests + @upcoming_contests).any?
      redirect_to history_contests_path
      return
    end
  end

  def show
    @vote = @contest.contest_votes.new if @contest.voting_enabled
    @contest_email = ContestEmail.new if @contest.voting_enabled
  end

  def history
    @contests = Contest.list_visible(:finished).reorder('last_day desc').decorate
  end

  def leaderboard
    @leaderboard_paginatable = Kaminari.paginate_array(@leaderboard).page(params[:page]).per(100)
  end

  def vote
    unless :running == @contest.status
      redirect_to action: :show && return
    end

    @contest_email = ContestEmail.find_or_new_by_email(permitted_params['contest_email']['email'])
    @vote = ContestVote.new(permitted_params.except(:contest_email).merge(contest_id: @contest.id))
    @vote.contest_email = @contest_email if !@contest_email.new_record? || @contest_email.save

    if permitted_params[:name].blank?
      @vote.errors.add(:name, t('activerecord.errors.messages.blank'))
    end
    if permitted_params['contest_email']['email'].blank?
      @vote.errors.add('contest_email.email', t('activerecord.errors.messages.blank'))
    end

    if verify_recaptcha && @vote.save
      @participant = @vote.participant
      if @vote.verified
        render_page_or_embed(:vote_registered)
      else
        verify_path = verify_contest_url(@contest.id, @contest_email.hash_code)
        UserMailer.contest_verification_email(@vote.id, verify_path, I18n.locale).deliver
        @vote.contest_email.update_attribute(:verification_sent, true)
        render_page_or_embed(:verification_email_sent)
      end
    else
      flash.delete(:recaptcha_error)
      @vote.errors.add(:base,
        t('errors.attributes.captcha.blank')) unless verify_recaptcha
      render_page_or_embed(:voting_form)
    end
  end

  def verify
    hash_code = params[:hash_code]
    if ce = ContestEmail.find_by(hash_code: hash_code)
      ce.verify
      @participant = ce.contest_votes.where(contest_id: @contest.id).last.participant

      render :vote_registered
    else
      render :hash_code_not_found
    end
  end

  def example
    @sdk_url = "#{sdk_url}.js"
    render layout: 'contests_embed'
  end

  def embed
    @vote = @contest.contest_votes.new
    @contest_email = ContestEmail.new
    @vote_section = 'voting_form'
    render :embed, layout: 'contests_embed'
  end

  private

  def find_contest
    @contest = Contest.find_by_url_or_id(params[:id] || params[:resource_id]).decorate
  end

  def render_page_or_embed(route)
    if params[:embed].present?
      @vote_section = route.to_s
      render :embed, layout: 'contests_embed'
    else
      render route
    end
  end

  def fill_leaderboard
    return unless @contest.leaderboard_enabled

    @leaderboard = @contest.leaderboard
    @leaderboard_top = @leaderboard.first(15)
  end

  def assign_date
    @date = params[:date].present? ? params[:date].to_date : Date.current
  end

  def allow_iframe
    response.headers.except! 'X-Frame-Options'
  end

  def permitted_params
    params.require(:contest_vote)
      .permit(:name, :participant_name, :profile_id, :signup_1, :signup_2, :signup_3,
        contest_email: [:email])
  end
end




### ActiveAdmin example for Contest model

# frozen_string_literal: true

ActiveAdmin.register Contest do
  menu parent: 'Content'
  config.sort_order = 'first_day_desc'

  filter :brigades, collection: Brigade.current_country.with_translations(I18n.locale).order(:name)
  filter :select_options, label: 'Organization type'

  form do |f|
    unless f.object.new_record?
      f.actions do
        ('Preview ' + [
          link_to(
            'Before start',
            contest_path(id: resource, date: (resource.first_day - 1.day))),
          link_to('Running', contest_path(id: resource, date: resource.first_day)),
          link_to('Ended', contest_path(id: resource, date: (resource.last_day + 1.day))),
          link_to('Embedded version', example_contest_path(resource))
        ].join(' - ')).html_safe
      end
    end
    f.inputs 'General Information' do
      f.input :brigades,
        as: :select,
        include_blank: false,
        collection: Brigade.current_country.with_translations(I18n.locale).order(:name)
      f.input :name
      f.input :url,
        as: :url_friendly,
        label: 'Page URL'
      f.input :header_image, as: :image
      f.input :short_description, as: :rich_text, feature_set: 'basic_block'
    end
    f.inputs 'Start &amp; End Dates' do
      f.input :first_day, as: :datepicker
      f.input :last_day, as: :datepicker
    end
    f.inputs 'Filtering and blacklisting' do
      f.input :select_options,
        as: :check_boxes,
        label: 'Organization types',
        collection: SelectOption.get_options('organization_types').order(:name)
      f.input :regions, as: :check_boxes, include_blank: false, label: 'Regions'
      f.input :users_list_white,
        as: :radio,
        collection: [['Blacklist', false], ['Whitelist', true]]
      f.input :users_list_ids,
        input_html: { rows: 2 },
        hint: 'Comma separated user IDs (e.g. 12345, 67890)'
    end
    f.inputs 'Content Sections' do
      f.input :intro_section, as: :editorium,  label: 'Intro Section'
      f.input :pre_start_section, as: :editorium,  label: 'Pre Start Section'
      f.input :vote_section, as: :editorium,  label: 'Vote Section'
      f.input :contest_end_section, as: :editorium,  label: 'Contest End Section'
      f.input :how_it_works_section, as: :editorium,  label: 'How It Works Section'
      f.input :prizes_section, as: :editorium,  label: 'Prizes Section'
      f.input :official_results_section, as: :editorium,  label: 'Official Results Section'
    end
    f.inputs 'Contest Card' do
      f.input :card_image, as: :image, label: 'Image', required: true
      f.input :recycling_program
      f.input :timeline
      f.input :how_it_works_section_simple, label: 'How To Win', input_html: { rows: 1 }
      f.input :prizes_section_simple, label: 'Prize', input_html: { rows: 1 }
      f.input :hide_card
    end
    f.inputs 'Settings' do
      f.input :credits_by_vote, min: 0
      f.input :credits_by_shipment, min: 0
      f.input :credits_by_unit, min: 0
      f.input :voting_enabled
      f.input :leaderboard_enabled
      f.input :show_credits
      f.input :leaderboard_display_address
    end
    f.inputs 'Agreement checkboxes' do
      f.input :checkbox_title_1, label: 'Checkbox 1'
      f.input :checkbox_title_2, label: 'Checkbox 2'
      f.input :checkbox_title_3, label: 'Checkbox 3'
    end
    f.inputs 'Embedded Contest' do
      f.input :iframe_css, input_html: { rows: 5, style: 'resize: vertical' }
    end
    f.actions
  end

  member_action :leaderboard do
    respond_to do |format|
      format.json { render json: resource.decorate.leaderboard.map, root: :contest_leaderboard }
      format.csv { render text: resource.decorate.leaderboard_csv }
      format.xlsx do
        file = resource.decorate.leaderboard_xlsx(current_user.admin?)
        send_data File.read(file), filename: "leaderboard-#{resource.name.parameterize}-" \
          "#{Time.current.strftime('%Y-%m-%d')}.xlsx"
        File.delete(file)
      end
    end
  end

  member_action :update_leaderboard do
    resource.invalidate_leaderboard
    redirect_to active_admin_contests_path,
      notice: "Leaderboard for '#{resource.name}' contest is generating..."
  end

  action_item :view_conteste_index do
    link_to('Show Contests', contests_path, target: :_blank)
  end

  action_item :contest_emails_index do
    link_to('Contest Emails', active_admin_contest_emails_path, target: :_blank)
  end

  controller do
    private

    def permitted_params
      params.require(:contest).permit(:name, :url,
        { intro_section_attributes: [:mobiledoc, :id] },
        { pre_start_section_attributes: [:mobiledoc, :id] },
        { vote_section_attributes: [:mobiledoc, :id] },
        { contest_end_section_attributes: [:mobiledoc, :id] },
        { how_it_works_section_attributes: [:mobiledoc, :id] },
        { prizes_section_attributes: [:mobiledoc, :id] },
        { official_results_section_attributes: [:mobiledoc, :id] },
        :first_day, :last_day, :checkbox_title_1, :checkbox_title_2, :checkbox_title_3,
        :users_list_ids, :users_list_white, :credits_by_vote, :credits_by_shipment,
        :credits_by_unit, :voting_enabled, :leaderboard_enabled, :show_credits,
        :leaderboard_display_address, :header_image, :short_description, :timeline,
        :recycling_program, :how_it_works_section_simple, :prizes_section_simple,
        :card_image, :hide_card, :iframe_css, select_option_ids: [], region_ids: [],
        brigade_ids: [])
    end
  end

  index do
    column :id
    column :name do |c|
      div class: 'contest-name' do
        name = c.name.nil? ? 'PLEASE TRANSLATE!' : c.name
        link_to name, edit_active_admin_contest_path(c.id)
      end
    end
    column :first_day do |c|
      c.first_day.strftime('%F')
    end
    column :last_day do |c|
      c.last_day.strftime('%F')
    end
    column 'Public View' do |c|
      link_to 'Link', contest_path(c.url || c), target: '_blank'
    end
    column 'Leaderboard' do |c|
      if c.leaderboard_enabled?
        link_to 'Update Now', update_leaderboard_active_admin_contest_path(c)
      else
        'Disabled'
      end
    end
    column :download do |c|
      links = ''.html_safe
      links += link_to 'Excel', leaderboard_active_admin_contest_path(c, format: :xlsx)
      links += link_to 'JSON', leaderboard_active_admin_contest_path(c, format: :json)
      links += link_to 'HTML', leaderboard_contest_path(c)
      links += link_to 'CSV', leaderboard_active_admin_contest_path(c, format: :csv)

      div class: 'contest-download' do
        links
      end
    end
    column('Status', :active) do |c|
      active_status_tag(Date.current.between?(c.first_day, c.last_day))
    end
  end
end




### Override of the default behaviour of ActiveAdmin controller
### This is needed to handle switching to the next not yet translated country after filling in first language
### Also get rid of duplications inside ActiveAdmin controllers

module ActiveAdmin
  ResourceController.class_eval do
    def scoped_collection
      chain = end_of_association_chain

      # records on the admin pages will be displayed by default based on the country_id
      # scope :current_country is not needed on the admin pages
      if resource_class.respond_to?(:current_country)
        chain = chain.current_country
      end

      if defined?(resource_class.translates?) && resource_class.translates? && params[:action] == 'index'
        locale = I18n.locale
        chain.with_translations(locale)
      else
        chain
      end
    end

    # ACTIONS
    def new
      init_resource_object
    end

    def create
      init_resource_object(update_params)
      if get_resource_object.save
        edit_next_missing_or_go_to_index
      else
        render :new
      end
    end

    def update
      if resource.update_attributes(update_params)
        edit_next_missing_or_go_to_index
      else
        render :edit
      end
    end

    def edit_next_missing_or_go_to_index
      if edit_enabled? &&
          resource_class.translates? &&
          nextlocale = resource.missing_translations_next_locale
        redirect_to current_path_with_locale(nextlocale, action: :edit, id: resource)
      else
        redirect_to(action: :index)
      end
    end

    private

    def update_params
      permitted_params || params[resource_class_name.to_sym]
    end

    def init_resource_object(options = {})
      instance_variable_set("@#{resource_class_name}", resource_class.new(options))
    end

    def get_resource_object
      instance_variable_get("@#{resource_class_name}")
    end

    def edit_enabled?
      action_methods.include?('edit')
    end

    def edit_resource?
      %{edit update}.include?(action_name)
    end

    def resource_class_name
      resource_class.name.underscore
    end
  end
end



### Contest specs

# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
describe Contest do
  let(:regions) { Region.current_country.pluck(:region_code) }
  let(:contest) { build :contest }
  let(:contest_saved) { create :contest }

  it { expect(contest).to be_valid }

  context '#name' do
    context 'valid' do
      it 'when present' do
        contest.name = 'Contest with name'
        expect(contest).to be_valid
      end

      it 'when name is unique' do
        expect(Contest.all.map(&:name)).to_not include(contest.name)
      end
    end

    context 'invalid' do
      it 'when is empty' do
        contest.name = nil
        expect(contest).to be_invalid
      end

      it 'when is not unique' do
        contest.name = contest_saved.name
        expect(contest).to be_invalid
      end
    end

    context 'with multiple locales' do
      before do
        contest.name_translations = {
          'en-US' => 'English Name',
          'hu-HU' => 'Hungarian Name'
        }
        contest.save
      end

      it 'correct English name' do
        Globalize.with_locale('en-US') do
          expect(contest.name).to eq 'English Name'
        end
      end

      it 'correct Other name' do
        Globalize.with_locale('hu-HU') do
          expect(contest.name).to eq 'Hungarian Name'
        end
      end
    end
  end

  context '#first_day, #last_day' do
    context 'valid' do
      it 'with valid dates and order' do
        expect(contest).to be_valid
      end
    end

    context 'invalid' do
      let(:contest_with_invalid_dates) { build :contest_with_invalid_dates }

      it 'when is empty' do
        contest.first_day = nil
        contest.last_day = nil
        expect(contest).to be_invalid
      end

      it 'when last_day sooner then first_day' do
        expect(contest_with_invalid_dates).to be_invalid
        expect(contest_with_invalid_dates.errors.messages.keys).to include(:last_day)
      end
    end
  end

  context '.card_image_presence_if_needed' do
    it 'when not present, but required' do
      contest.hide_card = false
      expect { contest.save! }.to raise_error ActiveRecord::RecordInvalid
      expect(contest.errors.messages.keys).to include(:card_image)
    end
  end

  context 'users list' do
    let(:profile1) { create(:user).current_profile }
    let(:profile2) { create(:user).current_profile }
    let(:profile3) { create(:user).current_profile }

    context 'invalid' do
      it 'when ids do not exists' do
        contest.users_list_ids = 'wrong1, wrong2'
        expect { contest.save! }.to raise_error ActiveRecord::RecordInvalid
        expect(contest.errors.messages.keys).to include(:users_list_ids)
      end
    end

    context '#whitelisted' do
      let(:contest_white) do
        create :contest,
          :whitelisted,
          users_list_ids: [profile1.user.id, profile2.user.id].join(',')
      end

      it '.allowed_profiles' do
        expect(contest_white.allowed_profiles).to include(profile1, profile2)
        expect(contest_white.allowed_profiles).to_not include(profile3)
      end
    end

    context '#blacklisted' do
      let(:contest_black) do
        create :contest,
          :blacklisted,
          users_list_ids: [profile2.user.id, profile3.user.id].join(',')
      end

      it '.allowed_profiles' do
        expect(contest_black.allowed_profiles).to include(profile1)
        expect(contest_black.allowed_profiles).to_not include(profile2, profile3)
      end
    end

    context '.contestant_list' do
      let(:contest_with_associations) { create(:contest_with_associations, participants_count: 10) }

      it 'with_associations' do
        expect(contest_with_associations.contestant_list.count).to eq(10)
      end
    end
  end

  context '.leaderboard' do
    let(:contest) { create(:contest_with_associations) }
    let(:participant1) { create(:contest_participant_school).current_profile }
    let(:participant2) { create(:contest_participant_school).current_profile }
    let!(:c1) { create :active_collection, profile: participant1, brigade: contest.brigades.first }
    let!(:c2) { create :active_collection, profile: participant2, brigade: contest.brigades.first }
    let(:contest_email1) { create :contest_email }
    let(:contest_email2) { create :contest_email }

    def participant_credits(p)
      contest.leaderboard_calc.detect { |u| u.id = p.id }.credits
    end

    it 'starting vote count equals 0' do
      expect(contest.leaderboard_calc.map(&:credits)).to match_array([0, 0])
    end

    it 'vote is counted after verification' do
      vote1 = create(
        :contest_vote,
        participant: participant1,
        contest: contest,
        contest_email: contest_email1
      )
      vote1.contest_email.verify
      expect(participant_credits(participant1)).to eq(1)

      vote2 = create(
        :contest_vote,
        participant: participant1,
        contest: contest,
        contest_email: contest_email2
      )
      vote2.contest_email.verify
      expect(participant_credits(participant1)).to eq(2)

      expect(contest.leaderboard_calc.map(&:credits)).to match_array([2, 0])
    end

    context 'change contest crediting settings' do
      let(:contest) do
        create :contest,
          credits_by_shipment: 0,
          credits_by_unit: 0,
          credits_by_vote: 0
      end

      def credits_by(attribute, val)
        contest.update_attributes("credits_by_#{attribute}" => val)
      end

      it 'credits_by_shipment = 5' do
        expect(participant_credits(participant1)).to eq(0)

        shipping_model = create :shipping_model
        contest.brigades.first.shipping_models << shipping_model

        label_request = create :label_request,
          collection: contest.brigades.first.collections.first,
          shipping_model: shipping_model
        label = create :label, label_request: label_request

        create :shipment, unpackaged_weight: 1, label: label

        expect { credits_by('shipment', 5) }.to change { participant_credits(participant1) }.by(5)
      end

      it 'credits_by_unit = 3' do
        expect(participant_credits(participant1)).to eq(0)

        shipping_model = create :shipping_model
        contest.brigades.first.shipping_models << shipping_model

        label_request = create :label_request,
          collection: contest.brigades.first.collections.first, shipping_model: shipping_model
        label = create :label, label_request: label_request

        shipment = create :shipment, unpackaged_weight: 7, label: label
        expect(shipment.units_collected).to eq(2)
        expect { credits_by('unit', 3) }.to change { participant_credits(participant1) }.by(6)
      end

      it 'credits_by_vote = 2' do
        expect(participant_credits(participant1)).to eq(0)

        vote1 = create(
          :contest_vote,
          participant: participant1,
          contest: contest,
          contest_email: contest_email1
        )
        vote1.contest_email.verify

        expect do
          credits_by('vote', 2)
        end.to change { participant_credits(participant1) }.from(0).to(2)

        vote2 = create(
          :contest_vote,
          participant: participant1,
          contest: contest,
          contest_email: contest_email2
        )
        expect do
          vote2.contest_email.verify
        end.to change { participant_credits(participant1) }.from(2).to(4)
      end
    end
  end

  context 'status' do
    let(:active_contest) { create(:active_contest) }
    let(:finished_contest) { create(:finished_contest) }
    let(:upcoming_contest) { create(:upcoming_contest) }

    it 'active' do
      expect(described_class.list_visible(:active)).to include(active_contest)
      expect(described_class.list_visible(:finished)).to_not include(active_contest)
      expect(described_class.list_visible(:upcoming)).to_not include(active_contest)
    end

    it 'finished' do
      expect(described_class.list_visible(:active)).to_not include(finished_contest)
      expect(described_class.list_visible(:finished)).to include(finished_contest)
      expect(described_class.list_visible(:upcoming)).to_not include(finished_contest)
    end

    it 'upcoming' do
      expect(described_class.list_visible(:active)).to_not include(upcoming_contest)
      expect(described_class.list_visible(:finished)).to_not include(upcoming_contest)
      expect(described_class.list_visible(:upcoming)).to include(upcoming_contest)
    end
  end

  context 'regions' do
    around do |example|
      saved_config_region = BEHAVIOR_CONFIG[:address_has_region]
      BEHAVIOR_CONFIG[:address_has_region] = true
      example.run
      BEHAVIOR_CONFIG[:address_has_region] = saved_config_region
    end

    let(:contest) { create(:contest_with_associations) }
    let(:participant1) { create(:contest_participant_school).current_profile }
    let(:participant2) { create(:contest_participant_school).current_profile }
    let(:participant3) { create(:user).current_profile }
    let!(:c1) { create :active_collection, profile: participant1, brigade: contest.brigades.first }
    let!(:c2) { create :active_collection, profile: participant2, brigade: contest.brigades.first }
    let!(:c3) { create :active_collection, profile: participant3, brigade: contest.brigades.first }
    let(:contest_email1) { create :contest_email }
    let(:contest_email2) { create :contest_email }

    describe '.allowed_profiles' do
      it 'with valid regions' do
        expect(contest.allowed_profiles).to include(participant1, participant2)
      end

      it 'with invalid regions' do
        expect(contest.allowed_profiles).to_not include(participant3)
      end
    end

    describe '.leaderboard' do
      let(:contest_with_associations) { create(:contest_with_associations, participants_count: 2) }

      it 'with valid contestants' do
        expect(contest.contestant_list).to include(participant1, participant2)
        expect(contest.leaderboard_calc.count).to eq(2)
      end

      it 'with invalid contestants' do
        expect(contest.contestant_list).to_not include(participant3)
        expect(contest.leaderboard_calc).to_not include(participant3.user.first_name)
      end
    end
  end
end
