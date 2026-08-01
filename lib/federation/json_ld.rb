module Federation
  # Hardcoded JSON-LD context — no JSON-LD processor, same call as Mobilizon
  # and WriteFreely. The extension term map mirrors Mobilizon's
  # make_json_ld_header (lib/federation/activity_pub/utils.ex:60-180) so a
  # Mobilizon peer parses our events on its own vocabulary.
  module JsonLd
    AS = "https://www.w3.org/ns/activitystreams".freeze
    SECURITY = "https://w3id.org/security/v1".freeze
    PUBLIC = "https://www.w3.org/ns/activitystreams#Public".freeze

    EXTENSIONS = {
      "sc" => "http://schema.org#",
      "ical" => "http://www.w3.org/2002/12/cal/ical#",
      "pt" => "https://joinpeertube.org/ns#",
      "toot" => "http://joinmastodon.org/ns#",
      "mz" => "https://mobilizon.org/ns#",
      "Hashtag" => "as:Hashtag",
      "manuallyApprovesFollowers" => "as:manuallyApprovesFollowers",
      "discoverable" => "toot:discoverable",
      "commentsEnabled" => {"@id" => "pt:commentsEnabled", "@type" => "sc:Boolean"},
      "joinMode" => {"@id" => "mz:joinMode", "@type" => "mz:joinModeType"},
      "externalParticipationUrl" => {"@id" => "mz:externalParticipationUrl", "@type" => "sc:URL"},
      "participantCount" => {"@id" => "mz:participantCount", "@type" => "sc:Integer"},
      "anonymousParticipationEnabled" => {"@id" => "mz:anonymousParticipationEnabled", "@type" => "sc:Boolean"},
      "maximumAttendeeCapacity" => {"@id" => "sc:maximumAttendeeCapacity", "@type" => "sc:Integer"},
      "remainingAttendeeCapacity" => {"@id" => "sc:remainingAttendeeCapacity", "@type" => "sc:Integer"},
      "location" => {"@id" => "sc:location", "@type" => "sc:Place"},
      "PostalAddress" => "sc:PostalAddress",
      "address" => {"@id" => "sc:address", "@type" => "sc:PostalAddress"},
      "streetAddress" => "sc:streetAddress",
      "addressLocality" => "sc:addressLocality",
      "addressRegion" => "sc:addressRegion",
      "addressCountry" => "sc:addressCountry",
      "postalCode" => "sc:postalCode",
      "timezone" => {"@id" => "mz:timezone", "@type" => "sc:Text"},
      "isOnline" => {"@id" => "mz:isOnline", "@type" => "sc:Boolean"},
      "status" => {"@id" => "ical:status", "@type" => "ical:status"},
      "uuid" => "sc:identifier",
      "category" => "sc:category",
      "inLanguage" => "sc:inLanguage"
    }.freeze

    module_function

    def context
      [AS, SECURITY, EXTENSIONS]
    end

    def actor_context
      [AS, SECURITY, {"manuallyApprovesFollowers" => "as:manuallyApprovesFollowers",
                      "toot" => "http://joinmastodon.org/ns#",
                      "discoverable" => "toot:discoverable"}]
    end
  end
end
