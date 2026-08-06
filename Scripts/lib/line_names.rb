# frozen_string_literal: true

# OSM route relations name the *run*, not the line: "<line> <origin>→<destination>", often with a
# direction annotation, and once per direction. The importer merges a direction pair into one
# logical line, so a raw relation name would label the merged line with one of its halves.
#
# Both the Chinese and the English label go through the same reduction here. Keeping them in one
# place is the point: `nameEn` previously had a weaker cleanup of its own, which is why English
# names shipped with unbalanced brackets ("Light Rail 614P (Tuen Mun Ferry Pier"), direction
# suffixes ("… (Inbound)") and run arrows ("Metro Line 2：Nanlu -> Nanchang East Railway Station")
# that the Chinese name never had.
module LineNames
  # Some mapped names use the keycap emoji for the line number ("洛阳轨道交通1️⃣号线").
  ENCLOSED_DIGITS = (0..9).to_h { |digit| ["#{digit}️⃣", digit.to_s] }.freeze

  # Longest first: "<=>" and "<->" must not be split by "=>" / "->".
  ARROW = /<=>|<->|-->|->|=>|→|➡|⇒|⟶/
  COLON = /[:：]/
  OPENERS = "(（[［【".freeze
  CLOSERS = ")）]］】".freeze
  BRACKET_PAIRS = { "(" => ")", "（" => "）", "[" => "]", "［" => "］", "【" => "】" }.freeze

  # A running direction is not a line a rider can board separately.
  ZH_DIRECTIONS = "順向|逆向|顺向|順行|逆行|顺行|上行|下行|南向|北向|東向|西向|东向|" \
                  "往程|返程|去程|回程|順時針|逆時針|方向"
  EN_DIRECTIONS = "northbound|southbound|eastbound|westbound|inbound|outbound|" \
                  "clockwise|anti-?clockwise|counterclockwise"
  DIRECTION = /#{ZH_DIRECTIONS}|#{EN_DIRECTIONS}/i

  # "…6号线-上行": the direction hangs off a hyphen instead of a bracket.
  HYPHEN_DIRECTION = /\s*[-‑]\s*(?:#{ZH_DIRECTIONS}|#{EN_DIRECTIONS})\s*\z/i
  # "臺中捷運綠線北屯總站方向": unparenthesised, anchored to the 線/线 that ends the line name.
  DIRECTION_TAIL = /(?<=線|线)[^線线]*方向\z/

  # A trailing "<origin>-<destination>" pair. Only ASCII/non-breaking hyphens: the en dash in
  # "重庆轨道交通4–环–5直通快速" joins the *lines* a through service runs over, not two termini.
  TERMINUS_PAIR = /\s+\S+\s*[-‑]\s*\S+\z/
  # The same pair with no space in front of it ("高雄捷運紅線岡山車站-小港"), anchored to the
  # 線/线 so the pair cannot swallow a line name that itself contains a hyphen.
  TERMINUS_TAIL = /(?<=線|线)[^線线\s]*[-‑][^線线]*\z/
  # English endpoints are multi-word ("Red Line Gangshan Station - Siaogang", "… T1 & T2 -> …"),
  # so neither the pair nor the run can be found by counting tokens off the separator. Cut after
  # the line's own designation instead. The designation must carry a digit ("Line 1", "Line S1",
  # "Line 614P"); a bare word after "Line" is the first token of the origin. A bracketed qualifier
  # is part of the line ("Line 6 (Changsha Metro) Huanghua Airport T1 & T2 -> Xiejiaqiao").
  EN_LINE_HEAD = /\A(.*?\bline(?:\s+[A-Za-z]*\d[A-Za-z0-9]*)?(?:\s*\([^()]*\))?)/i
  NOT_BRACKET = /[^()（）\[\]［］【】]/
  # Only when what follows really is a run or a hyphenated pair — "MRT red line (Xinbeitou Branch
  # Line)" and "Nanjing Metro Line S1-S7 Express" must survive intact.
  EN_RUN = /#{EN_LINE_HEAD}\s+#{NOT_BRACKET}*(?:#{ARROW})/
  EN_TERMINUS = /#{EN_LINE_HEAD}\s+#{NOT_BRACKET}*[-‑]\s*\S+\z/

  module_function

  # Reduces one raw OSM `name`/`name:zh`/`name:en` to the label the merged line should carry.
  # Returns nil for a value that reduces to nothing, so callers can fall back.
  def clean(raw)
    value = raw.to_s
    ENCLOSED_DIGITS.each { |emoji, digit| value = value.gsub(emoji, digit) }
    value = value.split(COLON, 2).first.to_s
    value = strip_annotations(value)
    value = strip_run_arrow(value)
    value = strip_annotations(value)
    value = strip_terminus_pair(value)
    value = repair_brackets(value)
    value = value.strip.sub(/\A地铁\s*/, "").sub(%r{[\s、,，/／-]+\z}, "").strip
    value.empty? ? nil : value
  end

  # Removes every trailing bracketed group that annotates a direction or a run, innermost last, so
  # a nested pair ("（坝堰（机场）→伊利健康谷）") is removed as one group rather than cut in half.
  def strip_annotations(value)
    result = value
    loop do
      head, inner = split_trailing_group(result)
      break if head.nil?
      break unless inner.match?(DIRECTION) || inner.match?(ARROW)

      result = head
    end
    result.sub(HYPHEN_DIRECTION, "").sub(DIRECTION_TAIL, "")
  end

  # Splits "<head>(<inner>)" on the bracket group that closes the string, honouring nesting.
  def split_trailing_group(value)
    trimmed = value.rstrip
    return nil unless CLOSERS.include?(trimmed[-1].to_s)

    depth = 0
    index = trimmed.length - 1
    while index >= 0
      character = trimmed[index]
      depth += 1 if CLOSERS.include?(character)
      if OPENERS.include?(character)
        depth -= 1
        return [trimmed[0...index].rstrip, trimmed[(index + 1)...-1]] if depth.zero?
      end
      index -= 1
    end
    nil
  end

  # An arrow that survived the bracket pass separates a run's endpoints inline
  # ("市郊铁路通密线: 通州西->怀柔北" once the colon is gone, "地铁1号线 麻丘 → 昌北机场").
  def strip_run_arrow(value)
    return value unless value.match?(ARROW)
    return Regexp.last_match(1) if value =~ EN_RUN

    # "<line> <origin>→…" keeps only the line. Requires the arrow, so a genuinely spaced name
    # such as "市郊铁路 怀密线" is never touched.
    return Regexp.last_match(1) if value =~ /\A(.+?)[[:space:]]+[^[:space:]]+[[:space:]]*#{ARROW}/

    value.split(ARROW, 2).first.to_s
  end

  def strip_terminus_pair(value)
    return Regexp.last_match(1) if value =~ EN_TERMINUS

    result = value.sub(TERMINUS_PAIR) do |pair|
      # "臺北捷運 南港-板橋-土城線" is a line name that contains hyphens, not a terminus pair.
      pair.match?(/(?:線|线|line)\s*\z/i) ? pair : ""
    end
    result.sub(TERMINUS_TAIL, "")
  end

  # Drops the tail from the first bracket left unclosed, which is what an inline arrow split
  # leaves behind ("Light Rail 614P (Tuen Mun Ferry Pier"). A closer whose width does not match
  # its opener is a mapping typo ("(普通列车）"), not an unbalanced bracket, so pair them by depth
  # and rewrite the closer to match.
  def repair_brackets(value)
    stack = []
    characters = value.chars
    characters.each_with_index do |character, index|
      if OPENERS.include?(character)
        stack.push(index)
      elsif CLOSERS.include?(character)
        opener = stack.pop
        next if opener.nil?

        characters[index] = BRACKET_PAIRS.fetch(characters[opener])
      end
    end
    stack.empty? ? characters.join : characters[0...stack.first].join
  end
end
