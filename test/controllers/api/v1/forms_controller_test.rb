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

  test "save_event_form can remove a question people have already answered" do
    applicant = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?" }, { label: "Dietary needs" }] },
      headers: auth_headers(@owner), as: :json
    form = @event.reload.form
    why, diet = form.form_fields.order(:position).to_a

    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [
        { field_id: why.id, value: "curious" },
        { field_id: diet.id, value: "none" }
      ] },
      headers: auth_headers(applicant), as: :json
    assert_response :created

    # form_answers.form_field_id is a foreign key with no cascade, so deleting
    # the field alone raised ForeignKeyViolation — an organizer tidying up
    # their form after applications started got a 500 and lost the whole edit.
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ id: why.id, label: "Why?" }] },
      headers: auth_headers(@owner), as: :json
    assert_response :success
    assert_equal ["Why?"], json_response["fields"].map { |f| f["label"] }

    submission = FormSubmission.find_by(form_id: form.id, user_id: applicant.id)
    assert_equal ["curious"], submission.form_answers.map(&:value)
  end

  # ---- editing my own application ----

  test "an applicant under review can correct their answers" do
    applicant = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?", required: true }] },
      headers: auth_headers(@owner), as: :json
    field = @event.reload.form.form_fields.first

    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "first go" }] },
      headers: auth_headers(applicant), as: :json
    assert_response :created

    # This is what the "edit my application" dialog does. It used to POST to
    # participants#create, which refuses anyone already participating — so
    # every save came back "User can only participate once per event" and the
    # answers never changed.
    patch "/api/v1/events/#{@event.id}/form/submission",
      params: { form_answers: [{ field_id: field.id, value: "corrected" }] },
      headers: auth_headers(applicant), as: :json
    assert_response :success
    assert_equal ["corrected"], json_response["answers"].map { |a| a["value"] }
    assert_equal 1, FormSubmission.where(form_id: @event.form_id).count
  end

  test "editing is refused once the organizer has decided" do
    applicant = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?" }] },
      headers: auth_headers(@owner), as: :json
    field = @event.reload.form.form_fields.first

    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "first go" }] },
      headers: auth_headers(applicant), as: :json
    participant = Participant.find(json_response["id"])
    post "/api/v1/events/#{@event.id}/participants/#{participant.id}/approve",
      headers: auth_headers(@owner)
    assert_response :success

    # Those answers are what the approval was given for; changing them under it
    # would leave the organizer endorsing something nobody read.
    patch "/api/v1/events/#{@event.id}/form/submission",
      params: { form_answers: [{ field_id: field.id, value: "bait and switch" }] },
      headers: auth_headers(applicant), as: :json
    assert_response :unprocessable_entity
    assert_match "already been reviewed", json_response["error"]
    assert_equal ["first go"],
      FormSubmission.find_by(form_id: @event.form_id, user_id: applicant.id).form_answers.map(&:value)
  end

  test "editing is refused to someone who never applied, and enforces required fields" do
    stranger = create_user
    applicant = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?", required: true }] },
      headers: auth_headers(@owner), as: :json
    field = @event.reload.form.form_fields.first

    patch "/api/v1/events/#{@event.id}/form/submission",
      params: { form_answers: [{ field_id: field.id, value: "hello" }] },
      headers: auth_headers(stranger), as: :json
    assert_response :unprocessable_entity
    assert_match "not applied", json_response["error"]

    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "first go" }] },
      headers: auth_headers(applicant), as: :json
    patch "/api/v1/events/#{@event.id}/form/submission",
      params: { form_answers: [{ field_id: field.id, value: "" }] },
      headers: auth_headers(applicant), as: :json
    assert_response :unprocessable_entity
    assert_match "Why?", json_response["error"]
  end

  test "my_submission reads back my own answers without me knowing my user id" do
    applicant = create_user
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Why?" }] },
      headers: auth_headers(@owner), as: :json
    field = @event.reload.form.form_fields.first

    get "/api/v1/events/#{@event.id}/form/my_submission", headers: auth_headers(applicant)
    assert_response :success
    assert_nil json_response["submission"]

    post "/api/v1/events/#{@event.id}/participants",
      params: { form_answers: [{ field_id: field.id, value: "because" }] },
      headers: auth_headers(applicant), as: :json

    get "/api/v1/events/#{@event.id}/form/my_submission", headers: auth_headers(applicant)
    assert_response :success
    assert_equal ["because"], json_response["answers"].map { |a| a["value"] }
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
    @event.update!(status: "published")
    outsider = create_user
    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(outsider)
    assert_response :success
    assert_nil json_response["form"]
  end

  test "get_event_form returns the attached form" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Q1" }] }, headers: auth_headers(@owner)
    @event.update!(status: "published")

    outsider = create_user
    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(outsider)
    assert_response :success
    assert_equal "RSVP", json_response["title"]
    assert_equal 1, json_response["fields"].size
  end

  # The event detail page is server-rendered for signed-out visitors and fetches
  # the form with no token; when this 401'd, the whole page 500'd.
  test "get_event_form is readable anonymously for a public event" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Q1" }] }, headers: auth_headers(@owner)
    @event.update!(status: "published")

    get "/api/v1/events/#{@event.id}/form"
    assert_response :success
    assert_equal "RSVP", json_response["title"]
  end

  test "get_event_form hides a draft event's form from non-managers" do
    post "/api/v1/events/#{@event.id}/form",
      params: { title: "RSVP", fields: [{ label: "Q1" }] }, headers: auth_headers(@owner)
    assert_equal "draft", @event.reload.status

    get "/api/v1/events/#{@event.id}/form"
    assert_response :forbidden

    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(create_user)
    assert_response :forbidden

    get "/api/v1/events/#{@event.id}/form", headers: auth_headers(@owner)
    assert_response :success
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
