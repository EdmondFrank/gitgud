defmodule GitGud.Web.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but it is primarily
  a collection of function components that serve as building blocks
  for your application's UI using Bulma CSS framework.

  The default components use Bulma CSS classes. Feel free to customize
  them to use your own CSS framework or design system.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide("##{@id}")}
      role="alert"
      class={[
        "message is-fixed",
        @kind == :info && "is-primary",
        @kind == :error && "is-danger"
      ]}
      {@rest}
    >
      <div class="message-header">
        <p><%= @title || if(@kind == :info, do: "Info", else: "Error") %></p>
        <button class="delete is-small" aria-label="delete"></button>
      </div>
      <div class="message-body"><%= msg %></div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title="Info" flash={@flash} />
      <.flash kind={:error} title="Error" flash={@flash} />
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"
  attr :rest, :global, doc: "the arbitrary HTML attributes for the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <%= render_slot(@inner_block, f) %>
      <div :for={action <- @actions} class="buttons">
        <%= render_slot(action) %>
      </div>
    </.form>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    - You may also set `type="select"` to render a `<select>` tag

    - `type="checkbox"` is used exclusively to render boolean values

    - For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global, doc: "the arbitrary HTML attributes for the input tag"

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field" phx-feedback-for={@name}>
      <label class="checkbox">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id || @name}
          name={@name}
          value="true"
          checked={@checked}
          class={["has-text-danger", @errors != []]}
          {@rest}
        />
        <%= @label %>
      </label>
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field" phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <div class="control">
        <div class="select">
          <select id={@id} name={@name} multiple={@multiple} {@rest}>
            <option :if={@prompt} value=""><%= @prompt %></option>
            <%= Phoenix.HTML.Form.options_for_select(@options, @value) %>
          </select>
        </div>
      </div>
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field" phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <div class="control">
        <textarea
          id={@id || @name}
          name={@name}
          class={["textarea", @errors != [] && "is-danger"]}
          {@rest}
        ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      </div>
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field" phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <div class="control">
        <input
          type={@type}
          name={@name}
          id={@id || @name}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={["input", @errors != [] && "is-danger"]}
          {@rest}
        />
      </div>
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="label">
      <%= render_slot(@inner_block) %>
    </label>
    """
  end

  @doc """
  Generates a generic error container for form inputs.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="help is-danger">
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["hero", @class]}>
      <div class="hero-body">
        <div class="container">
          <h1 class="title"><%= render_slot(@inner_block) %></h1>
          <div :for={action <- @actions} class="is-pulled-right">
            <%= render_slot(action) %>
          </div>
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row ID"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="table-container">
      <table class="table is-fullwidth is-hoverable" id={@id}>
        <thead>
          <tr>
            <th :for={col <- @col}><%= col[:label] %></th>
            <th :if={@action != []}>
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody id={"#{@id}-body"} phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class={@row_click && "is-clickable"}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={col[:class]}
            >
              <%= render_slot(col, @row_id && elem(row, 1) || row) %>
            </td>
            <td :if={@action != []}>
              <div class="buttons are-small">
                <%= for action <- @action do %>
                  <%= render_slot(action, @row_id && elem(row, 1) || row) %>
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title"><%= @post.title %></:item>
        <:item title="Views"><%= @post.views %></:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="content">
      <dl>
        <div :for={item <- @item} class="mb-4">
          <dt class="has-text-weight-bold"><%= item.title %></dt>
          <dd><%= render_slot(item) %></dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a back navigation link.
  """
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <p class="mb-4">
      <.link navigate={@navigate} class="button is-text">
        <.icon name="hero-arrow-left-solid" class="mr-1" />
        <%= render_slot(@inner_block) %>
      </.link>
    </p>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and CSS classes directly on the component.

  ## Examples

      <.icon name="hero-book-open" />
      <.icon name="hero-arrow-path" class="ml-1 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file error", "%{count} file errors", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by replacing the
    # placeholders. Note that we need to use the Gettext module to
    # do this because the Phoenix.HTML.Form message extraction tool
    # only looks for calls to Gettext.gettext/2 and similar.
    if count = opts[:count] do
      Gettext.dngettext(GitGud.Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GitGud.Web.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg) do
    Gettext.dgettext(GitGud.Web.Gettext, "errors", msg)
  end
end
