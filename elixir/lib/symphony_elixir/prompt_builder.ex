defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!(issue)
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @spec uses_state_specific_prompt?(SymphonyElixir.Linear.Issue.t()) :: boolean()
  def uses_state_specific_prompt?(issue) do
    issue
    |> Map.get(:state)
    |> Config.codex_review_state?()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}, issue) do
    if uses_state_specific_prompt?(issue) do
      default_codex_review_prompt(Config.codex_review_prompt())
    else
      default_prompt(prompt)
    end
  end

  defp prompt_template!({:error, reason}, _issue) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp default_codex_review_prompt(prompt) when is_binary(prompt) do
    prompt
  end

  defp default_codex_review_prompt(_prompt) do
    """
    You are performing a Codex review for a Linear issue.

    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}
    Current status: {{ issue.state }}

    Body:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}

    Instructions:

    1. Inspect the raw handoff package, changed files, and local workspace diff before asking for human input.
    2. Run the verification commands required by the issue and by the repository instructions.
    3. Fix low-risk review findings directly when the fix is clear and within the issue scope.
    4. Add a concise Codex Review Brief to Linear with artifact paths, acceptance assessment, verification evidence, risks, and a recommendation.
    5. Stop for human judgment only when product semantics, credentials, permissions, security, or high-risk data behavior require it.
    """
  end
end
