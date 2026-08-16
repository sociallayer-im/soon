class FormFieldBlueprint < Blueprinter::Base
  identifier :id
  fields :label, :field_type, :required, :for_admin, :position, :options
end

class FormBlueprint < Blueprinter::Base
  identifier :id
  # slug is what a shareable /form/<slug> link is built from; without it the
  # standalone pages can only address a form by its opaque id.
  fields :title, :description, :published, :slug, :submission_message,
         :public_submissions, :created_at

  view :extended do
    association :form_fields, blueprint: FormFieldBlueprint, name: :fields

    # Set when an event uses this form as its registration questions. Such a
    # form is answered by joining the event, not by posting here — the fill
    # page needs to know before it offers a submit button it cannot honour.
    field :event_id do |form|
      Event.where(form_id: form.id).pick(:id)
    end

    # Whether the CALLER may edit it. Now that a form's responses can be public,
    # the responses page has readers who are signed in and are not the author;
    # without this it offered them an "Edit form" link that only fails when
    # followed. Passed in rather than derived here — a blueprint has no caller.
    field :can_edit do |_form, options|
      options[:can_edit] == true
    end
  end

  # For the "forms I created" list: the response count is the thing that list
  # is really asking about. Both maps are passed in already grouped rather
  # than counted per row — a hub page listing 40 forms would otherwise cost 80
  # queries to render three numbers.
  view :with_counts do
    field :submission_count do |form, options|
      options[:submission_counts]&.fetch(form.id, 0) || 0
    end
    field :field_count do |form|
      form.form_fields.size
    end
    # An event-attached form is edited from the event page, not here. The list
    # needs to know which, so it can link to the right place instead of
    # offering an editor that would fight with the event's own.
    field :event_id do |form, options|
      options[:event_ids]&.[](form.id)
    end
  end
end
