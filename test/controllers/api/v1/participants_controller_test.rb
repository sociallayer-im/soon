require "test_helper"

class Api::V1::ParticipantsControllerTest < ActionDispatch::IntegrationTest
  test "create defaults to attending when no approval/form is required" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "attending", json_response["status"]
  end

  test "create is pending when event.require_approval is true and caller isn't a group admin" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "create is attending (bypasses approval) when caller is a group admin" do
    owner = create_user
    admin = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "admin")
    event = create_event(group: group, owner: owner, require_approval: true)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(admin)
    assert_response :created
    assert_equal "attending", json_response["status"]
  end

  test "create is pending when the event has a form attached" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :created
    assert_equal "pending", json_response["status"]
  end

  test "create rejects join when a required form field is missing" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)
    field = create_form_field(form: form, required: true, for_admin: false)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
    assert_match "missing required form fields", json_response["error"]
    assert_not event.participants.exists?(user: attendee)
  end

  test "create succeeds and stores answers when required fields are present" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    form = create_form
    event.update_column(:form_id, form.id)
    field = create_form_field(form: form, required: true, for_admin: false)

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "yes" }] },
      headers: auth_headers(attendee)
    assert_response :created

    submission = FormSubmission.find_by(form: form, user: attendee)
    assert submission
    assert_equal "yes", submission.form_answers.first.value
  end

  test "create rejects a duplicate participant for the same user/event" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: attendee)

    post "/api/v1/events/#{event.id}/participants", headers: auth_headers(attendee)
    assert_response :unprocessable_entity
  end

  test "index lists participants for an event" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    create_participant(event: event, user: attendee)

    get "/api/v1/events/#{event.id}/participants", headers: auth_headers(owner)
    assert_response :success
    assert_equal 1, json_response["data"].size
  end

  test "update is self-only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee)

    patch "/api/v1/events/#{event.id}/participants/#{participant.id}",
      params: { participant: { status: "maybe" } }, headers: auth_headers(outsider)
    assert_response :forbidden

    patch "/api/v1/events/#{event.id}/participants/#{participant.id}",
      params: { participant: { status: "maybe" } }, headers: auth_headers(attendee)
    assert_response :success
    assert_equal "maybe", participant.reload.status
  end

  test "destroy is self-only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee)

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(outsider)
    assert_response :forbidden

    delete "/api/v1/events/#{event.id}/participants/#{participant.id}", headers: auth_headers(attendee)
    assert_response :no_content
  end

  test "approve moves a pending participant to attending, event owner only" do
    owner = create_user
    attendee = create_user
    outsider = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner, require_approval: true)
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(outsider)
    assert_response :forbidden

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "approve works for a group admin too, not just the event owner" do
    owner = create_user
    admin = create_user
    attendee = create_user
    group = create_group(owner: owner)
    create_membership(user: admin, group: group, role: "admin")
    event = create_event(group: group, owner: owner, require_approval: true)
    participant = create_participant(event: event, user: attendee, status: "pending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(admin)
    assert_response :success
    assert_equal "attending", participant.reload.status
  end

  test "approve 422s on a non-pending participant" do
    owner = create_user
    attendee = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)
    participant = create_participant(event: event, user: attendee, status: "attending")

    post "/api/v1/events/#{event.id}/participants/#{participant.id}/approve", headers: auth_headers(owner)
    assert_response :unprocessable_entity
    assert_equal "attending", participant.reload.status
  end

  test "approve 404s for an unknown participant" do
    owner = create_user
    group = create_group(owner: owner)
    event = create_event(group: group, owner: owner)

    post "/api/v1/events/#{event.id}/participants/does-not-exist/approve", headers: auth_headers(owner)
    assert_response :not_found
  end
end
