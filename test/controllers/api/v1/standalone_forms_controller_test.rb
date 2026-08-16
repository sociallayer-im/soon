require "test_helper"

class Api::V1::StandaloneFormsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @author = create_user
    @responder = create_user
  end

  def create_published_form(fields: [{ label: "Name", field_type: "text", required: true }])
    post "/api/v1/forms",
      params: { title: "Survey", description: "tell us", published: true, fields: fields },
      headers: auth_headers(@author), as: :json
    assert_response :created
    Form.find(json_response["id"])
  end

  # ---- authoring ----

  test "create returns a form with a shareable slug and its fields" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true, fields: [
        { label: "Name", field_type: "text", required: true },
        { label: "Photo", field_type: "image" }
      ] },
      headers: auth_headers(@author), as: :json

    assert_response :created
    assert_equal "Survey", json_response["title"]
    assert json_response["slug"].present?
    assert_equal %w[text image], json_response["fields"].map { |f| f["field_type"] }
  end

  test "create requires authentication" do
    post "/api/v1/forms", params: { title: "Survey" }, as: :json
    assert_response :unauthorized
  end

  test "index lists my forms with response counts, not other people's" do
    mine = create_published_form
    create_form(created_by_id: @responder.id)
    FormSubmission.create!(form: mine, user: @responder, submitted_at: Time.current)

    get "/api/v1/forms", headers: auth_headers(@author)
    assert_response :success
    rows = json_response["data"]
    assert_equal [mine.id], rows.map { |f| f["id"] }
    assert_equal 1, rows.first["submission_count"]
    assert_equal 1, rows.first["field_count"]
    # Nothing points at it, so there is no event editor to defer to.
    assert_nil rows.first["event_id"]
  end

  test "index marks an event's registration form with the event that owns it" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)
    form = create_form(created_by_id: @author.id)
    event.update!(form_id: form.id)

    get "/api/v1/forms", headers: auth_headers(@author)
    assert_response :success
    row = json_response["data"].find { |f| f["id"] == form.id }
    assert row.present?, "an event form I created is still a form I created"
    assert_equal event.id, row["event_id"]
  end

  test "update edits the questions and can unpublish" do
    form = create_published_form
    field_id = form.form_fields.first.id

    patch "/api/v1/forms/#{form.slug}",
      params: { title: "Survey v2", published: false, fields: [
        { id: field_id, label: "Full name", field_type: "text" },
        { label: "CV", field_type: "file" }
      ] },
      headers: auth_headers(@author), as: :json

    assert_response :success
    assert_equal "Survey v2", json_response["title"]
    assert_equal false, json_response["published"]
    assert_equal ["Full name", "CV"], json_response["fields"].map { |f| f["label"] }
    assert_equal field_id, json_response["fields"].first["id"], "an edited field keeps its id, so existing answers still point at it"
  end

  test "update is refused to anyone but the author" do
    form = create_published_form
    patch "/api/v1/forms/#{form.slug}", params: { title: "Mine now" },
      headers: auth_headers(@responder), as: :json
    assert_response :forbidden
    assert_equal "Survey", form.reload.title
  end

  test "destroy is refused while an event still uses the form" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)
    form = create_published_form
    event.update!(form_id: form.id)

    delete "/api/v1/forms/#{form.slug}", headers: auth_headers(@author)
    assert_response :unprocessable_entity
    assert Form.exists?(form.id)
  end

  test "destroy removes a form nothing points at" do
    form = create_published_form
    delete "/api/v1/forms/#{form.slug}", headers: auth_headers(@author)
    assert_response :no_content
    assert_not Form.exists?(form.id)
  end

  # ---- reading ----

  test "show is public for a published form so a link can be shared" do
    form = create_published_form
    get "/api/v1/forms/#{form.slug}"
    assert_response :success
    assert_equal "Name", json_response["fields"].first["label"]
  end

  test "show hides an unpublished form from everyone but its author" do
    form = create_published_form
    form.update!(published: false)

    get "/api/v1/forms/#{form.slug}"
    assert_response :not_found
    get "/api/v1/forms/#{form.slug}", headers: auth_headers(@responder)
    assert_response :not_found
    get "/api/v1/forms/#{form.slug}", headers: auth_headers(@author)
    assert_response :success
  end

  # ---- filling in, and filling in again ----

  test "submit records answers and rejects a missing required one" do
    form = create_published_form
    field = form.form_fields.first

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :unprocessable_entity
    assert_match "Name", json_response["error"]

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :created
    assert_equal "Ada", json_response["answers"].first["value"]
  end

  test "re-submitting EDITS the existing answer instead of filing a second one" do
    form = create_published_form
    field = form.form_fields.first

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json
    first_id = json_response["id"]

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada Lovelace" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :success

    assert_equal first_id, json_response["id"]
    assert_equal 1, FormSubmission.where(form_id: form.id, user_id: @responder.id).count
    assert_equal ["Ada Lovelace"], json_response["answers"].map { |a| a["value"] }
    assert_equal 1, json_response["answers"].size, "the superseded answer is replaced, not appended"
  end

  test "editing an already-decided submission returns it to pending" do
    form = create_published_form
    field = form.form_fields.first
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json
    submission = FormSubmission.find(json_response["id"])
    submission.update!(status: "approved")

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "someone else entirely" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :success
    # An approval is a decision about specific answers; changing them under it
    # would leave the organizer endorsing something they never read.
    assert_equal "pending", json_response["status"]
  end

  test "submit is refused on an unpublished form" do
    form = create_published_form
    form.update!(published: false)
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [] }, headers: auth_headers(@author), as: :json
    assert_response :unprocessable_entity
    assert_match "not accepting", json_response["error"]
  end

  test "my_submission hands back my own answers for prefilling, null when I have none" do
    form = create_published_form
    field = form.form_fields.first

    get "/api/v1/forms/#{form.slug}/my_submission", headers: auth_headers(@responder)
    assert_response :success
    assert_nil json_response["submission"]

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json

    get "/api/v1/forms/#{form.slug}/my_submission", headers: auth_headers(@responder)
    assert_response :success
    assert_equal "Ada", json_response["answers"].first["value"]
  end

  test "my_submissions lists the forms I filled in, with the questions attached" do
    form = create_published_form
    field = form.form_fields.first
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json

    get "/api/v1/forms/submissions", headers: auth_headers(@responder)
    assert_response :success
    assert_equal 1, json_response["data"].size
    assert_equal "Survey", json_response["data"].first["form"]["title"]
    assert_equal "Name", json_response["data"].first["form"]["fields"].first["label"]

    # …and not anyone else's.
    get "/api/v1/forms/submissions", headers: auth_headers(@author)
    assert_equal 0, json_response["data"].size
  end

  test "submissions is the author's view and closed to the people who filled it in" do
    form = create_published_form
    field = form.form_fields.first
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json

    get "/api/v1/forms/#{form.slug}/submissions", headers: auth_headers(@responder)
    assert_response :forbidden

    get "/api/v1/forms/#{form.slug}/submissions", headers: auth_headers(@author)
    assert_response :success
    assert_equal 1, json_response["data"].size
    assert_equal 1, json_response["meta"]["total"]
    assert_equal @responder.id, json_response["data"].first["user_id"]
  end

  # ---- publishing the answers ----

  test "submissions stay private by default, even from a signed-in stranger" do
    form = create_published_form
    assert_not form.public_submissions, "opt-in: an existing form cannot start publishing answers"

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: form.form_fields.first.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json

    get "/api/v1/forms/#{form.slug}/submissions"
    assert_response :forbidden
    get "/api/v1/forms/#{form.slug}/submissions", headers: auth_headers(@responder)
    assert_response :forbidden
  end

  test "public_submissions opens the answers to everyone, signed out included" do
    form = create_published_form
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: form.form_fields.first.id, value: "Ada" }] },
      headers: auth_headers(@responder), as: :json

    patch "/api/v1/forms/#{form.slug}", params: { public_submissions: true },
      headers: auth_headers(@author), as: :json
    assert_response :success
    assert_equal true, json_response["public_submissions"]

    get "/api/v1/forms/#{form.slug}/submissions"
    assert_response :success
    assert_equal 1, json_response["data"].size
    assert_equal "Ada", json_response["data"].first["answers"].first["value"]

    # The respondent is shown the way the attendee list shows people — handle
    # and avatar. Publishing answers must not publish contact details.
    user = json_response["data"].first["user"]
    assert user["name"].present?
    assert_not user.key?("email"), "email is PII and has no view that a stranger can reach"
    assert_not user.key?("phone")
  end

  test "an unpublished form keeps its answers private however the flag is set" do
    form = create_published_form
    patch "/api/v1/forms/#{form.slug}", params: { public_submissions: true, published: false },
      headers: auth_headers(@author), as: :json
    assert_response :success

    # A draft is not something a stranger is meant to reach at all, so
    # publishing its responses would be a stranger surprise than the flag
    # promises.
    get "/api/v1/forms/#{form.slug}/submissions"
    assert_response :forbidden
    get "/api/v1/forms/#{form.slug}/submissions", headers: auth_headers(@author)
    assert_response :success
  end

  test "the flag belongs to the form, so an event's registration answers can be published too" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)

    post "/api/v1/events/#{event.id}/form",
      params: { title: "RSVP", public_submissions: true,
                fields: [{ label: "Why?", field_type: "textarea" }] },
      headers: auth_headers(@author), as: :json
    assert_response :success
    form = event.reload.form
    assert form.public_submissions

    post "/api/v1/events/#{event.id}/participants",
      params: { form_answers: [{ field_id: form.form_fields.first.id, value: "curious" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :created

    get "/api/v1/forms/#{form.slug}/submissions"
    assert_response :success
    assert_equal ["curious"], json_response["data"].first["answers"].map { |a| a["value"] }
  end

  test "save_event_form leaves the flag alone when it is not sent" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)
    post "/api/v1/events/#{event.id}/form",
      params: { title: "RSVP", public_submissions: true, fields: [{ label: "Why?" }] },
      headers: auth_headers(@author), as: :json

    # An editor that predates the flag posts no key for it; that must not read
    # as "turn it off" and silently unpublish a wall of answers.
    post "/api/v1/events/#{event.id}/form",
      params: { title: "RSVP v2", fields: [{ label: "Why?" }] },
      headers: auth_headers(@author), as: :json
    assert_response :success
    assert event.reload.form.public_submissions
  end

  test "can_edit tells a public reader they are not the author" do
    form = create_published_form
    patch "/api/v1/forms/#{form.slug}", params: { public_submissions: true },
      headers: auth_headers(@author), as: :json

    get "/api/v1/forms/#{form.slug}", headers: auth_headers(@author)
    assert_equal true, json_response["can_edit"]

    # A signed-in reader of a public form is not its author. Without this the
    # responses page offered them an edit link that only fails when followed.
    get "/api/v1/forms/#{form.slug}", headers: auth_headers(@responder)
    assert_equal false, json_response["can_edit"]

    get "/api/v1/forms/#{form.slug}"
    assert_equal false, json_response["can_edit"]
  end

  # ---- field types ----

  test "the long-text, date and url types are accepted and round-trip" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true, fields: [
        { label: "Tell us more", field_type: "textarea" },
        { label: "When", field_type: "date" },
        { label: "Your site", field_type: "url" }
      ] },
      headers: auth_headers(@author), as: :json

    assert_response :created
    assert_equal %w[textarea date url], json_response["fields"].map { |f| f["field_type"] }
  end

  test "multi_select keeps its options and a plain text field does not" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true, fields: [
        { label: "Pick any", field_type: "multi_select", options: %w[a b c] },
        { label: "Free text", field_type: "text", options: %w[ignored] }
      ] },
      headers: auth_headers(@author), as: :json

    assert_response :created
    assert_equal %w[a b c], json_response["fields"].first["options"]
    assert_equal [], json_response["fields"].last["options"],
      "a stale option list must not survive a change to a type that has no choices"
  end

  test "a multi_select answer is the chosen options in one value" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true,
                fields: [{ label: "Pick any", field_type: "multi_select", options: %w[a b c] }] },
      headers: auth_headers(@author), as: :json
    form = Form.find(json_response["id"])

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: form.form_fields.first.id, value: "a|c" }] },
      headers: auth_headers(@responder), as: :json

    assert_response :created
    # One row, one value — no answer-per-choice, so nothing about the schema
    # or the dedupe-by-field rule changes.
    assert_equal 1, json_response["answers"].size
    assert_equal "a|c", json_response["answers"].first["value"]
  end

  test "an option cannot contain the separator a multi_select answer is joined by" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true,
                fields: [{ label: "Pick any", field_type: "multi_select", options: ["a|b", "c"] }] },
      headers: auth_headers(@author), as: :json

    # Silently rewriting it would leave the choice list not matching the
    # answers already stored against it; the author can see this and reword.
    assert_response :unprocessable_entity
    assert_match "cannot contain", json_response["error"]
    assert_equal 0, Form.where(created_by_id: @author.id).count
  end

  test "an unknown field type still degrades to text rather than failing the save" do
    post "/api/v1/forms",
      params: { title: "Survey", published: true,
                fields: [{ label: "From the future", field_type: "colour-picker" }] },
      headers: auth_headers(@author), as: :json
    assert_response :created
    assert_equal "text", json_response["fields"].first["field_type"]
  end

  # ---- editing a form people have already answered ----

  test "removing a question people already answered succeeds, and takes those answers with it" do
    form = create_published_form(fields: [{ label: "Keep" }, { label: "Drop" }])
    keep, drop = form.form_fields.order(:position).to_a

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: keep.id, value: "kept" }, { field_id: drop.id, value: "dropped" }] },
      headers: auth_headers(@responder), as: :json
    assert_response :created

    # form_answers.form_field_id is a foreign key with NO cascade: deleting the
    # field alone raises ForeignKeyViolation, so this used to 500 for any
    # organizer editing a form after the first response arrived.
    patch "/api/v1/forms/#{form.slug}",
      params: { fields: [{ id: keep.id, label: "Keep" }] },
      headers: auth_headers(@author), as: :json
    assert_response :success
    assert_equal ["Keep"], json_response["fields"].map { |f| f["label"] }

    submission = FormSubmission.find_by(form_id: form.id, user_id: @responder.id)
    assert_equal ["kept"], submission.form_answers.map(&:value),
      "the answer to a deleted question goes with it — nothing is left to label it"
  end

  test "deleting a form people already answered succeeds" do
    form = create_published_form
    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: form.form_fields.first.id, value: "x" }] },
      headers: auth_headers(@responder), as: :json

    # Same foreign key, reached the other way: dependent: :destroy runs in
    # declaration order, so the submissions have to go before the fields.
    delete "/api/v1/forms/#{form.slug}", headers: auth_headers(@author)
    assert_response :no_content
    assert_not Form.exists?(form.id)
    assert_equal 0, FormSubmission.where(form_id: form.id).count
    assert_equal 0, FormField.where(form_id: form.id).count
  end

  # ---- the event's registration form is not a second front door ----

  test "submit is refused for a form an event owns" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)
    form = create_published_form
    event.update!(form_id: form.id)
    field = form.form_fields.first

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [{ field_id: field.id, value: "sneaking in" }] },
      headers: auth_headers(@responder), as: :json

    # Answering here would file an application with no Participant behind it —
    # invisible on the event's applicant list, and impossible to approve.
    assert_response :unprocessable_entity
    assert_match "belongs to an event", json_response["error"]
    assert_equal 0, FormSubmission.where(form_id: form.id).count
  end

  test "an event's form still reads, and says which event owns it" do
    group = create_group(owner: @author)
    event = create_event(group: group, owner: @author)
    form = create_published_form
    event.update!(form_id: form.id)

    get "/api/v1/forms/#{form.slug}"
    assert_response :success
    assert_equal event.id, json_response["event_id"],
      "the fill page needs this to send people to the event instead of offering a submit it cannot honour"
  end

  test "a standalone form carries no event_id" do
    form = create_published_form
    get "/api/v1/forms/#{form.slug}"
    assert_response :success
    assert_nil json_response["event_id"]
  end

  test "the submissions collection route is not mistaken for a form named 'submissions'" do
    create_published_form
    get "/api/v1/forms/submissions", headers: auth_headers(@author)
    assert_response :success
    assert_kind_of Array, json_response["data"]
  end

  test "a repeated field_id writes one answer, not one per repetition" do
    form = create_published_form
    field = form.form_fields.first

    post "/api/v1/forms/#{form.slug}/submissions",
      params: { answers: [
        { field_id: field.id, value: "first" },
        { field_id: field.id, value: "second" },
        { field_id: field.id, value: "third" },
        # A field id from no form at all is dropped rather than written.
        { field_id: "not-a-field", value: "injected" }
      ] },
      headers: auth_headers(@responder), as: :json

    assert_response :created
    # There is no unique index on (submission, field), so without the dedupe a
    # client could write unbounded rows for one question — all but one of which
    # nothing would ever display.
    assert_equal 1, json_response["answers"].size
    assert_equal "third", json_response["answers"].first["value"], "the last one sent wins"
    assert_equal 1, FormAnswer.where(form_submission_id: json_response["id"]).count
  end
end
