class RegistrationBlueprint < ParticipantBlueprint
  association :event, blueprint: EventBlueprint
end
