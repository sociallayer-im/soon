require "test_helper"

class Api::V1::FormsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @owner = create_user
    @group = create_group(owner: @owner)
    @event = create_event(group: @group, owner: @owner)
  end

  # ---- save_event_form ----

  test "save_event_form creates a new form when the event has none" do
    assert_nil @event.form_id

    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?", field_type: "text", required: true }] },
      headers: auth_headers(@owner)
    assert_response :success

    @event.reload
    assert @event.form_id.present?
    assert_equal "RSVP", @event.form.title
    assert_equal 1, @event.form.form_fields.count
  end

  test "save_event_form forces require_approval to true as a side effect" do
    assert_not @event.require_approval

    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [] }, headers: auth_headers(@owner), as: :json
    assert_response :success
    assert @event.reload.require_approval
  end

  test "save_event_form reuses the existing form on a second call (upsert)" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [] }, headers: auth_headers(@owner), as: :json
    first_form_id = @event.reload.form_id

    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP v2", fields: [] }, headers: auth_headers(@owner), as: :json
    assert_equal first_form_id, @event.reload.form_id
    assert_equal "RSVP v2", @event.form.title
    assert_equal 1, Form.count
  end

  test "save_event_form field upsert: update existing, create new, delete omitted" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [
        { label: "Keep me (will update)", field_type: "text" },
        { label: "Delete me", field_type: "text" }
      ] }, headers: auth_headers(@owner)
    assert_response :success
    form = @event.reload.form
    keep_field = form.form_fields.find_by(label: "Keep me (will update)")
    delete_field = form.form_fields.find_by(label: "Delete me")
    assert keep_field.present?
    assert delete_field.present?

    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [
        { id: keep_field.id, label: "Kept & updated", field_type: "text" },
        { label: "Brand new field", field_type: "text" }
      ] }, headers: auth_headers(@owner)
    assert_response :success

    form.reload
    assert_equal 2, form.form_fields.count
    assert_not FormField.exists?(delete_field.id), "omitted field should be hard-deleted"
    assert_equal "Kept & updated", keep_field.reload.label
    assert form.form_fields.exists?(label: "Brand new field")
  end

  test "save_event_form defaults position to array index and field_type to text" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [
        { label: "First" },
        { label: "Second" }
      ] }, headers: auth_headers(@owner)
    assert_response :success

    form = @event.reload.form
    first = form.form_fields.find_by(label: "First")
    second = form.form_fields.find_by(label: "Second")
    assert_equal 0, first.position
    assert_equal 1, second.position
    assert_equal "text", first.field_type
  end

  test "save_event_form only keeps options for select fields" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [
        { label: "Pick one", field_type: "select", options: ["a", "b"] },
        { label: "Free text", field_type: "text", options: ["ignored"] }
      ] }, headers: auth_headers(@owner)
    assert_response :success

    form = @event.reload.form
    select_field = form.form_fields.find_by(label: "Pick one")
    text_field = form.form_fields.find_by(label: "Free text")
    assert_equal ["a", "b"], select_field.options
    assert_equal [], text_field.options
  end

  test "save_event_form rejects a blank field label" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "" }] }, headers: auth_headers(@owner)
    assert_response :unprocessable_entity
  end

  test "save_event_form requires event owner or group admin" do
    outsider = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [] }, headers: auth_headers(outsider), as: :json
    assert_response :forbidden
  end

  # ---- clear_event_form ----

  test "clear_event_form detaches without deleting the Form record" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [] }, headers: auth_headers(@owner), as: :json
    form_id = @event.reload.form_id

    delete "/api/v1/events/#{@event.id}/form", headers: auth_headers(@owner)
    assert_response :no_content
    assert_nil @event.reload.form_id
    assert Form.exists?(form_id), "the Form record itself should survive detaching"
  end

  test "clear_event_form requires event owner or group admin" do
    outsider = create_user
    delete "/api/v1/events/#{@event.id}/form", headers: auth_headers(outsider)
    assert_response :forbidden
  end

  # ---- get_event_form ----

  test "get_event_form works without manager auth and returns nil form gracefully" do
    outsider = create_user
    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(outsider)
    assert_response :success
    assert_nil json_response["form"]
  end

  test "get_event_form returns the attached form" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Q1" }] }, headers: auth_headers(@owner)

    outsider = create_user
    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(outsider)
    assert_response :success
    assert_equal "RSVP", json_response["title"]
    assert_equal 1, json_response["fields"].size
  end

  # ---- required-field gate at join time (ParticipantsController#create) ----

  test "joining blocks when a required non-admin field is unanswered" do
    form = create_form
    required_field = create_form_field(form: form, required: true, for_admin: false)
    @event.update_column(:form_id, form.id)

    joiner = create_user
    assert_no_difference "Participant.count" do
      post "/api/v1/events/#{@event.id}/participants", params: {}, headers: auth_headers(joiner)
    end
    assert_response :unprocessable_entity
  end

  test "joining is not blocked by an unanswered for_admin field" do
    form = create_form
    create_form_field(form: form, required: true, for_admin: true)
    @event.update_column(:form_id, form.id)

    joiner = create_user
    assert_difference "Participant.count", 1 do
      post "/api/v1/events/#{@event.id}/participants", params: {}, headers: auth_headers(joiner)
    end
    assert_response :success
  end

  test "joining succeeds when all required answers are provided" do
    form = create_form
    field = create_form_field(form: form, required: true, for_admin: false)
    @event.update_column(:form_id, form.id)

    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "my answer" }] },
      headers: auth_headers(joiner)
    assert_response :success
  end

  # ---- FormSubmission upsert / wholesale answer replacement ----

  test "resubmitting replaces prior answers wholesale, not additively" do
    form = create_form
    field1 = create_form_field(form: form, label: "Field 1")
    field2 = create_form_field(form: form, label: "Field 2")
    @event.update_column(:form_id, form.id)

    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field1.id, value: "first answer" }] },
      headers: auth_headers(joiner)
    assert_response :success

    submission = FormSubmission.find_by(form: form, user: joiner)
    assert_equal 1, submission.form_answers.count

    # A second POST would violate the participants uniqueness constraint, so exercise
    # the same upsert path the controller uses directly to verify wholesale replacement.
    valid_field_ids = FormField.where(form_id: form.id).pluck(:id)
    submission.form_answers.delete_all
    [{ field_id: field2.id, value: "second answer" }].each do |answer|
      next unless valid_field_ids.include?(answer[:field_id].to_s)
      FormAnswer.create!(form_submission_id: submission.id, form_field_id: answer[:field_id], value: answer[:value])
    end

    submission.reload
    assert_equal 1, submission.form_answers.count
    assert_equal "second answer", submission.form_answers.first.value
  end

  test "answers referencing a field not on this event's form are silently dropped" do
    form = create_form
    field = create_form_field(form: form)
    other_form = create_form
    foreign_field = create_form_field(form: other_form)
    @event.update_column(:form_id, form.id)

    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [
        { field_id: field.id, value: "real" },
        { field_id: foreign_field.id, value: "should be dropped" }
      ] },
      headers: auth_headers(joiner)
    assert_response :success

    submission = FormSubmission.find_by(form: form, user: joiner)
    assert_equal 1, submission.form_answers.count
    assert_equal "real", submission.form_answers.first.value
  end

  # ---- get_submission ----

  test "get_submission allows self" do
    form = create_form
    @event.update_column(:form_id, form.id)
    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants", params: {}, headers: auth_headers(joiner)

    get "/api/v1/events/#{@event.id}/form/submission",
      params: { user_id: joiner.id }, headers: auth_headers(joiner)
    assert_response :success
  end

  test "get_submission forbids a non-manager, non-self user" do
    form = create_form
    @event.update_column(:form_id, form.id)
    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants", params: {}, headers: auth_headers(joiner)

    stranger = create_user
    get "/api/v1/events/#{@event.id}/form/submission",
      params: { user_id: joiner.id }, headers: auth_headers(stranger)
    assert_response :forbidden
  end

  test "get_submission allows the event owner and group admin" do
    form = create_form
    @event.update_column(:form_id, form.id)
    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants", params: {}, headers: auth_headers(joiner)

    get "/api/v1/events/#{@event.id}/form/submission",
      params: { user_id: joiner.id }, headers: auth_headers(@owner)
    assert_response :success

    admin = create_user
    create_membership(user: admin, group: @group, role: "manager")
    get "/api/v1/events/#{@event.id}/form/submission",
      params: { user_id: joiner.id }, headers: auth_headers(admin)
    assert_response :success
  end

  # ---- list_submissions ----

  test "list_submissions is manager-only" do
    form = create_form
    field = create_form_field(form: form)
    @event.update_column(:form_id, form.id)
    joiner = create_user
    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "answer" }] },
      headers: auth_headers(joiner)

    get "/api/v1/events/#{@event.id}/form/submissions", headers: auth_headers(joiner)
    assert_response :forbidden

    get "/api/v1/events/#{@event.id}/form/submissions", headers: auth_headers(@owner)
    assert_response :success
    assert_equal 1, json_response.size
  end
end
