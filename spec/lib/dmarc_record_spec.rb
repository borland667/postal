# frozen_string_literal: true

require "rails_helper"

describe DMARCRecord do
  def parse(record)
    DMARCRecord.new(record)
  end

  describe "record syntax" do
    it "accepts a normal, well formed record" do
      record = parse("v=DMARC1; p=reject; rua=mailto:dmarc-reports@example.com")
      expect(record).to be_valid
      expect(record.tags["p"]).to eq "reject"
    end

    it "tolerates whitespace around delimiters" do
      record = parse("  v=DMARC1 ;  p=reject  ; adkim=s  ")
      expect(record).to be_valid
      expect(record.adkim).to eq "s"
    end

    it "records a record split across TXT strings as joined by the resolver" do
      record = parse("v=DMARC1; p=reje" + "ct; rua=mailto:a@example.com")
      expect(record).to be_valid
      expect(record.policy).to eq "reject"
    end

    it "requires v to be the first tag" do
      record = parse("p=reject; v=DMARC1")
      expect(record).not_to be_valid
      expect(record.problems).to include("the v tag must be first")
    end

    it "requires the version to be exactly DMARC1, case sensitively" do
      record = parse("v=dmarc1; p=reject")
      expect(record).not_to be_valid
      expect(record.problems).to include("v must be DMARC1")
    end

    it "rejects a record with no version at all" do
      record = parse("p=reject")
      expect(record).not_to be_valid
    end

    it "rejects a malformed tag" do
      record = parse("v=DMARC1; banana")
      expect(record).not_to be_valid
    end

    it "rejects a duplicated tag" do
      record = parse("v=DMARC1; p=none; p=reject")
      expect(record).not_to be_valid
      expect(record.problems).to include("duplicate tag: p")
    end

    it "identifies a DMARC record by its leading version tag" do
      expect(DMARCRecord.dmarc_record?("v=DMARC1; p=none")).to be true
      expect(DMARCRecord.dmarc_record?("v=DKIM1; k=rsa; p=abc")).to be false
      expect(DMARCRecord.dmarc_record?("V=DMARC1")).to be false
    end
  end

  describe "unknown and deprecated tags" do
    it "ignores unknown tags without invalidating the record" do
      record = parse("v=DMARC1; p=none; foo=bar")
      expect(record).to be_valid
      expect(record.notes).to include("unknown tag ignored: foo")
    end

    it "ignores pct, rf and ri, which RFC 9989 removed" do
      record = parse("v=DMARC1; p=reject; pct=25; rf=afrf; ri=86400")
      expect(record).to be_valid
      expect(record.policy).to eq "reject"
      expect(record.notes).to include("pct is no longer part of DMARC and is ignored")
      expect(record.notes).to include("rf is no longer part of DMARC and is ignored")
      expect(record.notes).to include("ri is no longer part of DMARC and is ignored")
    end

    it "ignores the obsolete report size suffix on rua and ruf" do
      record = parse("v=DMARC1; p=reject; rua=mailto:a@example.com!10m,mailto:b@example.com!5m")
      expect(record).to be_valid
      expect(record.report_uris).to eq ["mailto:a@example.com", "mailto:b@example.com"]
      expect(record.notes).to include("the !size suffix on rua is obsolete and was ignored")
    end
  end

  describe "policy" do
    it "accepts the three published policies" do
      %w[none quarantine reject].each do |policy|
        expect(parse("v=DMARC1; p=#{policy}").policy).to eq policy
      end
    end

    it "rejects an invalid policy" do
      record = parse("v=DMARC1; p=banana")
      expect(record).not_to be_valid
      expect(record.problems).to include("invalid p value: banana")
    end

    it "treats a record with no policy but a valid reporting address as p=none" do
      record = parse("v=DMARC1; rua=mailto:reports@example.com")
      expect(record).to be_valid
      expect(record.policy).to eq "none"
      expect(record.notes).to include("no p tag; a record with rua but no p is treated as p=none")
    end

    it "has no policy to apply when neither p nor rua is present" do
      record = parse("v=DMARC1")
      expect(record).to be_valid
      expect(record.policy).to be_nil
    end

    it "validates the subdomain policies" do
      expect(parse("v=DMARC1; p=reject; sp=quarantine; np=none").subdomain_policy).to eq "quarantine"
      expect(parse("v=DMARC1; p=reject; np=none").nonexistent_subdomain_policy).to eq "none"
      record = parse("v=DMARC1; p=reject; sp=banana")
      expect(record).not_to be_valid
      expect(record.problems).to include("invalid sp value: banana")
    end

    it "falls back to p when no subdomain policy is published" do
      record = parse("v=DMARC1; p=quarantine")
      expect(record.subdomain_policy).to eq "quarantine"
      expect(record.nonexistent_subdomain_policy).to eq "quarantine"
    end
  end

  describe "test mode" do
    it "applies one level less than the published policy when t=y" do
      record = parse("v=DMARC1; p=reject; t=y")
      expect(record).to be_valid
      expect(record.test_mode?).to be true
      expect(record.applied_policy).to eq "quarantine"
    end

    it "steps quarantine down to none" do
      expect(parse("v=DMARC1; p=quarantine; t=y").applied_policy).to eq "none"
    end

    it "does nothing when the policy is already none" do
      expect(parse("v=DMARC1; p=none; t=y").applied_policy).to eq "none"
    end

    it "defaults to not being in test mode" do
      expect(parse("v=DMARC1; p=reject").test_mode?).to be false
    end

    it "rejects an invalid test mode value" do
      record = parse("v=DMARC1; p=reject; t=banana")
      expect(record).not_to be_valid
      expect(record.problems).to include("invalid t value: banana")
    end
  end

  describe "alignment and public suffix flags" do
    it "reports the alignment modes with their defaults" do
      record = parse("v=DMARC1; p=reject")
      expect(record.adkim).to eq "r"
      expect(record.aspf).to eq "r"
    end

    it "validates alignment values" do
      record = parse("v=DMARC1; p=reject; aspf=x")
      expect(record).not_to be_valid
      expect(record.problems).to include("invalid aspf value: x")
    end

    it "flags a record that requires strict SPF alignment" do
      record = parse("v=DMARC1; p=reject; aspf=s")
      expect(record).to be_valid
      expect(record.strict_spf_alignment?).to be true
      expect(parse("v=DMARC1; p=reject").strict_spf_alignment?).to be false
    end

    it "accepts psd and reports whether the walk should stop" do
      expect(parse("v=DMARC1; p=none; psd=y").public_suffix_domain?).to be true
      expect(parse("v=DMARC1; p=none; psd=n").stop_walk?).to be true
      expect(parse("v=DMARC1; p=none").stop_walk?).to be false
    end

    it "rejects an invalid psd value" do
      record = parse("v=DMARC1; p=none; psd=banana")
      expect(record).not_to be_valid
    end
  end

  describe "reporting addresses" do
    it "accepts a comma separated list of URIs" do
      record = parse("v=DMARC1; p=reject; rua=mailto:a@example.com,https://reports.example.com/dmarc")
      expect(record).to be_valid
      expect(record.report_uris.size).to eq 2
    end

    it "rejects an unparsable reporting URI" do
      record = parse("v=DMARC1; p=reject; rua=not-a-uri")
      expect(record).not_to be_valid
      expect(record.problems).to include("unparsable rua: not-a-uri")
    end

    it "notes when a mailto report address is outside the published domain" do
      record = DMARCRecord.new("v=DMARC1; p=reject; rua=mailto:reports@other.example", domain: "example.com")
      expect(record).to be_valid
      expect(record.notes).to include("the rua reporting domain (other.example) is not the published domain or a subdomain of it")
    end

    it "does not complain about a report address at or under the published domain" do
      record = DMARCRecord.new("v=DMARC1; p=reject; rua=mailto:reports@dmarc.example.com", domain: "example.com")
      expect(record).to be_valid
      expect(record.notes).to be_empty
    end

    it "ignores fo when no failure report address is published" do
      record = parse("v=DMARC1; p=reject; fo=d")
      expect(record).to be_valid
      expect(record.notes).to include("fo is ignored because no ruf address is published")
    end

    it "rejects a nonsensical failure option combination" do
      record = parse("v=DMARC1; p=reject; ruf=mailto:a@example.com; fo=0:1")
      expect(record).not_to be_valid
      expect(record.problems).to include("fo cannot contain both 0 and 1")
    end

    it "accepts valid failure options" do
      record = parse("v=DMARC1; p=reject; ruf=mailto:a@example.com; fo=d:s")
      expect(record).to be_valid
      expect(record.failure_options).to eq %w[d s]
    end
  end

  describe "summary" do
    it "describes the record for an operator" do
      record = parse("v=DMARC1; p=reject; sp=none; aspf=s; t=y")
      expect(record.summary).to eq "p=reject (test mode: quarantine), sp=none, adkim=r, aspf=s"
    end
  end
end
