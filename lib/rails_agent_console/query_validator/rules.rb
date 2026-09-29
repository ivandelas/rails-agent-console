# frozen_string_literal: true

require "set"

module RailsAgentConsole
  class QueryValidator
    module Rules
      FORBIDDEN = %w[
        eval instance_eval class_eval module_eval instance_exec class_exec binding
        send __send__ public_send method define_method method_missing
        system exec spawn fork syscall exit exit! abort at_exit trap sleep
        require require_relative load autoload open popen
        const_get const_set remove_const instance_variable_get instance_variable_set
        class_variable_get class_variable_set attr_accessor alias_method undef_method
        connection connection_pool with_connection raw_connection execute exec_query
        exec_update exec_delete select_all select_one select_value find_by_sql
        count_by_sql sanitize_sql create_table drop_table change_table add_column
        remove_column rename_table truncate truncate_tables migrate rollback
        establish_connection remove_connection instance_variables methods
        caller caller_locations gets `
      ].to_set.freeze

      WRITE = %w[
        save save! create create! create_or_find_by create_or_find_by!
        find_or_create_by find_or_create_by! first_or_create first_or_create!
        first_or_initialize new build update update! update_attribute
        update_attributes update_column update_columns update_all upsert upsert_all
        insert insert! insert_all insert_all! import touch touch_all
        increment! decrement! toggle! reset_counters
        delete delete_all delete_by destroy destroy! destroy_all destroy_by
        transaction lock lock! with_lock
      ].to_set.freeze

      DESTRUCTIVE = %w[
        delete delete_all delete_by destroy destroy! destroy_all destroy_by
        update_all update_column update_columns
      ].to_set.freeze

      ALLOWED = %w[
        all where not or and rewhere unscope only except merge none from
        joins left_joins left_outer_joins includes preload eager_load references
        group having order reorder reverse_order in_order_of
        limit offset distinct select pluck pick ids extract_associated
        readonly strict_loading annotate optimizer_hints with
        find find_by find_by! first first! last last! take take! sole find_sole_by
        find_each find_in_batches in_batches each each_with_index each_with_object
        exists? any? many? empty? none? one? present? blank? nil? include?
        count sum average minimum maximum size length calculate tally
        group_by index_by index_with partition
        map collect flat_map filter_map filter reject sort sort_by
        min min_by max max_by reduce inject zip uniq compact flatten
        to_a to_ary to_h to_hash keys values values_at fetch dig slice
        transform_values transform_keys invert drop take_while drop_while
        reverse sample shuffle rotate chunk_while each_slice each_cons
        to_s to_i to_f to_r to_d to_sym inspect round abs ceil floor
        divmod fdiv clamp between? positive? negative? zero? nonzero? nan? infinite?
        upcase downcase capitalize titleize humanize pluralize singularize
        strip chomp split join gsub sub start_with? end_with? match match? scan
        present blank squish truncate_words
        ago from_now since until seconds second minutes minute hours hour
        days day weeks week fortnight months month years year
        beginning_of_day end_of_day midnight noon beginning_of_hour end_of_hour
        beginning_of_minute end_of_minute
        beginning_of_week end_of_week beginning_of_month end_of_month
        beginning_of_quarter end_of_quarter beginning_of_year end_of_year
        all_day all_week all_month all_quarter all_year
        today yesterday tomorrow current now at parse iso8601 strftime
        to_date to_time to_datetime in_time_zone utc localtime change advance
        prev_day next_day prev_week next_week prev_month next_month
        prev_year next_year monday sunday wday yday cweek on_weekend? on_weekday?
        new_offset zone
        sql cast lower upper
        rand hex uuid alphanumeric random_number
        attributes attribute_names as_json to_json column_names table_name
        primary_key model_name human_attribute_name arel_table type_for_attribute
        puts pp print p format sprintf tap then yield_self lambda proc
      ].to_set.freeze

      CONSTRUCTORS = %w[new build].to_set.freeze

      UNSAFE_LOAD_RECEIVERS = %w[
        Kernel Object Module Class Marshal YAML Psych JSON ERB File IO Dir
      ].to_set.freeze

      BLOCKED_CONSTANTS = (UNSAFE_LOAD_RECEIVERS + %w[
        ENV Process Open3 Socket Net Shellwords Tempfile Pathname Gem Bundler
        Sidekiq ActionMailer
      ]).to_set.freeze

      VALUE_CONSTANTS = %w[
        Time Date DateTime TimeZone Range Hash Array Set String Symbol
        Integer Float Rational BigDecimal Struct Arel
      ].to_set.freeze

      SAFE_CONSTANTS = %w[
        Time Date DateTime ActiveSupport TimeZone Arel Float Integer Numeric String
        Symbol Hash Array Range Set Math Rational BigDecimal Comparable Struct
        SecureRandom ActiveRecord Base Relation Rails
      ].to_set.freeze

      DANGEROUS_SQL = /
        \b(delete\s+from|drop\s+(table|database|index|schema)|truncate\s+table|
        insert\s+into|update\s+\w+\s+set|alter\s+table|grant\s+|create\s+table)\b |
        ;\s*(select|delete|drop|update|insert|alter|attach)\b
      /ix
    end
  end
end
