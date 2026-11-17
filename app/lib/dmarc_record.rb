# frozen_string_literal: true

require "uri"

# A DMARC policy record as published in the TXT record at _dmarc.<domain>.
#
# RFC 9989 (DMARCbis) is the reference. The rules that matter for a receiver
# that wants to be compatible with both RFC 7489 and RFC 9989 implementations:
#
#   * unknown tags, and the tags RFC 9989 retired (pct, rf, ri), are ignored
#     rather than treated as errors;
#   * the "!size" suffix on a reporting address is obsolete and ignored;
#   * a record with a valid reporting address but no valid policy is treated
#     as p=none;
#   * psd stops the DNS tree walk and tells us whether the name we queried is
#     a public suffix domain or an organizational domain in its own right.
#
# This class only parses and validates. It never makes a delivery decision.
class DMARCRecord

  # Order matters: it is the ladder t=y steps down one rung at a time.
  POLICIES = %w[none quarantine reject].freeze
  KNOWN_TAGS = %w[v p sp np psd t adkim aspf rua ruf fo].freeze
  DEPRECATED_TAGS = %w[pct rf ri].freeze
  YES_NO = %w[y n].freeze
  ALIGNMENT_MODES = %w[r s].freeze
  PSD_VALUES = %w[y n u].freeze
  FAILURE_OPTIONS = %w[0 1 d s].freeze

  attr_reader :tags, :problems, :notes, :failure_options

  # Is this TXT record a DMARC record at all? The version tag is case
  # sensitive and must come first, so anything that does not start with
  # v=DMARC1 is not one.
  def self.dmarc_record?(record)
    record.to_s.strip.start_with?("v=DMARC1")
  end

  # @param record [String] the raw record, already concatenated if the DNS
  #   server split it across multiple TXT strings.
  # @param domain [String] the domain the record was found at, used only to
  #   sanity check where reporting addresses point to.
  def initialize(record, domain: nil)
    @raw = record.to_s
    @domain = domain
    @tags = {}
    @problems = []
    @notes = []
    @report_uris = {}
    @failure_options = nil
    parse_tags
    validate_version
    validate_reports
    validate_failure_options
    validate_policy
    validate_alignment
    validate_test_mode
    validate_psd
  end

  def valid?
    problems.empty?
  end

  # The policy the record publishes. nil means there is no policy to apply.
  attr_reader :policy

  # The policy actually in force once test mode is taken into account: t=y
  # asks receivers to apply one level less than the published policy.
  def applied_policy
    return @policy unless test_mode?
    return @policy if @policy.nil?

    level = POLICIES.index(@policy)
    level.zero? ? @policy : POLICIES[level - 1]
  end

  def test_mode?
    tags["t"] == "y"
  end

  # Every reporting address published in rua or ruf.
  def report_uris
    @report_uris.values.flatten
  end

  def aggregate_report_uris
    @report_uris["rua"] || []
  end

  def failure_report_uris
    @report_uris["ruf"] || []
  end

  # Policy for subdomains of the organizational domain that do exist.
  def subdomain_policy
    tags["sp"] || policy
  end

  # Policy for subdomains that don't exist at all (RFC 9989's np, formerly
  # RFC 9091's fallback).
  def nonexistent_subdomain_policy
    tags["np"] || subdomain_policy
  end

  def adkim
    tags["adkim"] || "r"
  end

  def aspf
    tags["aspf"] || "r"
  end

  def strict_spf_alignment?
    aspf == "s"
  end

  def public_suffix_domain?
    tags["psd"] == "y"
  end

  # The tree walk stops at a name whose record declares psd=y or psd=n.
  def stop_walk?
    %w[y n].include?(tags["psd"])
  end

  def summary
    parts = []
    if policy
      if test_mode? && applied_policy != policy
        parts << "p=#{policy} (test mode: #{applied_policy})"
      else
        parts << "p=#{policy}"
      end
    else
      parts << "no policy published"
    end
    parts << "sp=#{tags['sp']}" if tags["sp"]
    parts << "np=#{tags['np']}" if tags["np"]
    parts << "adkim=#{adkim}"
    parts << "aspf=#{aspf}"
    parts.join(", ")
  end

  private

  def parse_tags
    @raw.split(";").each do |part|
      part = part.strip
      next if part.empty?

      key, value = part.split("=", 2)
      key = key.to_s.strip.downcase
      value = value.to_s.strip

      if key.empty? || value.empty?
        problems << "malformed tag: #{part}"
        next
      end

      if tags.key?(key)
        problems << "duplicate tag: #{key}"
        next
      end

      if DEPRECATED_TAGS.include?(key)
        notes << "#{key} is no longer part of DMARC and is ignored"
        next
      end

      unless KNOWN_TAGS.include?(key)
        notes << "unknown tag ignored: #{key}"
        next
      end

      tags[key] = value
    end
  end

  def validate_version
    first = @raw.split(";").map(&:strip).reject(&:empty?).first.to_s.split("=").first.to_s.strip
    problems << "the v tag must be first" unless first == "v"
    problems << "v must be DMARC1" unless tags["v"] == "DMARC1"
  end

  def validate_reports
    %w[rua ruf].each do |tag|
      value = tags[tag]
      next if value.nil?

      uris = []
      value.split(",").each do |item|
        item = item.strip
        uri, size = item.split("!", 2)
        if size
          notes << "the !size suffix on #{tag} is obsolete and was ignored"
        end

        begin
          parsed = URI.parse(uri)
        rescue URI::InvalidURIError
          problems << "unparsable #{tag}: #{uri}"
          next
        end

        if parsed.scheme.nil?
          problems << "unparsable #{tag}: #{uri}"
          next
        end

        uris << uri
        report_domain = reporting_domain(parsed)
        if report_domain && @domain && !reporting_address_matches_domain?(report_domain)
          notes << "the #{tag} reporting domain (#{report_domain}) is not the published domain or a subdomain of it"
        end
      end
      @report_uris[tag] = uris
    end
  end

  # A mailto: URI is opaque to URI.parse, so the reporting domain has to be
  # taken from the address itself.
  def reporting_domain(uri)
    if uri.scheme == "mailto"
      address = uri.to_s.split("@", 2).last.to_s
      address.split("/").first
    else
      uri.host
    end
  end

  def reporting_address_matches_domain?(report_domain)
    report_domain == @domain || report_domain.end_with?(".#{@domain}")
  end

  def validate_failure_options
    value = tags["fo"]
    return if value.nil?

    if tags["ruf"].nil?
      notes << "fo is ignored because no ruf address is published"
      return
    end

    options = value.split(":").map(&:strip)
    problems << "invalid fo value: #{value}" unless options.all? { |option| FAILURE_OPTIONS.include?(option) }
    problems << "fo cannot contain both 0 and 1" if options.include?("0") && options.include?("1")
    @failure_options = options
  end

  def validate_policy
    published = tags["p"]
    if published.nil?
      if @report_uris["rua"] && !@report_uris["rua"].empty?
        @policy = "none"
        notes << "no p tag; a record with rua but no p is treated as p=none"
      else
        @policy = nil
      end
    elsif POLICIES.include?(published)
      @policy = published
    else
      problems << "invalid p value: #{published}"
      @policy = nil
    end

    %w[sp np].each do |tag|
      next if tags[tag].nil?

      problems << "invalid #{tag} value: #{tags[tag]}" unless POLICIES.include?(tags[tag])
    end
  end

  def validate_alignment
    %w[adkim aspf].each do |tag|
      next if tags[tag].nil?

      problems << "invalid #{tag} value: #{tags[tag]}" unless ALIGNMENT_MODES.include?(tags[tag])
    end
  end

  def validate_test_mode
    value = tags["t"]
    return if value.nil?

    problems << "invalid t value: #{value}" unless YES_NO.include?(value)
  end

  def validate_psd
    value = tags["psd"]
    return if value.nil?

    problems << "invalid psd value: #{value}" unless PSD_VALUES.include?(value)
  end

end
