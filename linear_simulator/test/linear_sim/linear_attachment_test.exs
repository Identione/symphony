defmodule LinearSim.LinearAttachmentTest do
  @moduledoc """
  Context-level coverage for attachment link/create/read/update/delete.

  The two creation paths intentionally diverge to match live Linear (verified
  2026-06-18, see docs/plans/attachment-support.md §"Verified"):
  `link_url/1` (backs the link* mutations) errors on a duplicate `(issue, url)`;
  `create_attachment/1` (backs `attachmentCreate`) upserts.
  """
  use LinearSim.DataCase, async: false

  alias LinearSim.Linear

  setup do
    %{org: Linear.default_organization()}
  end

  describe "create_attachment/1 (upsert)" do
    test "creates an attachment bound to an issue resolved by identifier" do
      assert {:ok, att} =
               Linear.create_attachment(%{
                 "issue_id" => "ENG-1",
                 "url" => "https://github.com/acme/repo/pull/1",
                 "title" => "PR #1"
               })

      assert att.title == "PR #1"
      assert att.url == "https://github.com/acme/repo/pull/1"
      assert String.starts_with?(att.id, "att_")
      assert att.issue.identifier == "ENG-1"
    end

    test "upserts on (issue_id, url): second call updates title in place, no duplicate", %{
      org: org
    } do
      url = "https://github.com/acme/repo/pull/2"

      assert {:ok, first} =
               Linear.create_attachment(%{"issue_id" => "ENG-1", "url" => url, "title" => "A"})

      assert {:ok, second} =
               Linear.create_attachment(%{"issue_id" => "ENG-1", "url" => url, "title" => "B"})

      assert first.id == second.id
      assert second.title == "B"
      assert length(Linear.list_attachments_for_url(org, url)) == 1
    end

    test "returns :issue_not_found for an unknown issue" do
      assert {:error, :issue_not_found} =
               Linear.create_attachment(%{
                 "issue_id" => "NOPE-9",
                 "url" => "https://x",
                 "title" => "t"
               })
    end
  end

  describe "link_url/1 (errors on duplicate, matching prod)" do
    test "first link succeeds and binds to the issue" do
      assert {:ok, att} =
               Linear.link_url(%{
                 "issue_id" => "ENG-1",
                 "url" => "https://x/pr/3",
                 "title" => "t"
               })

      assert att.issue.identifier == "ENG-1"
    end

    test "second link to the same url errors with the issue identifier, no duplicate", %{org: org} do
      url = "https://x/pr/4"
      assert {:ok, _} = Linear.link_url(%{"issue_id" => "ENG-1", "url" => url, "title" => "t"})

      assert {:error, {:already_linked, "ENG-1"}} =
               Linear.link_url(%{"issue_id" => "ENG-1", "url" => url, "title" => "t2"})

      assert length(Linear.list_attachments_for_url(org, url)) == 1
    end
  end

  describe "update_attachment/2 and delete_attachment/1" do
    test "updates the title and deletes" do
      {:ok, att} =
        Linear.create_attachment(%{
          "issue_id" => "ENG-1",
          "url" => "https://x/pr/5",
          "title" => "old"
        })

      assert {:ok, updated} = Linear.update_attachment(att.id, %{"title" => "new"})
      assert updated.title == "new"

      assert {:ok, _} = Linear.delete_attachment(att.id)
      assert Linear.get_attachment(att.id) == nil
    end

    test "update/delete of an unknown id returns :not_found" do
      assert {:error, :not_found} = Linear.update_attachment("att_missing", %{"title" => "x"})
      assert {:error, :not_found} = Linear.delete_attachment("att_missing")
    end
  end
end
