$:.unshift "spec/"
require './spec/spec_helper'

require 'xiki/core/git'

describe Git, "#status_to_hash_new" do
  it "Populates untracked key" do
    txt = "
      ?? a.txt
      ?? b.txt
    ".unindent
    Git.status_to_hash(txt).should == {:untracked=>[["untracked", "a.txt"], ["untracked", "b.txt"]], :unadded=>[], :added=>[]}
  end

  it "Populates unadded key" do
    txt = "
      AM a.txt
       M committed.txt
       D deleteme.txt
    ".unindent
    Git.status_to_hash(txt).should == {:unadded=>[["modified", "a.txt"], ["modified", "committed.txt"], ["deleted", "deleteme.txt"]], :untracked=>[], :added=>[["new file", "a.txt"]]}
  end

  it "Populates added keys" do
    txt = "
      AM a.txt
      A  d/d.txt
      R  rename.txt -> renamed.txt
    ".unindent
    Git.status_to_hash(txt)[:added].should == [["new file", "a.txt"], ["new file", "d/d.txt"], ["renamed", "rename.txt -> renamed.txt"]]
  end

end

require 'xiki/core/shell'
require 'xiki/core/tree'
require 'xiki/core/bookmarks'
require './roots/git'

describe Xiki::Menu::Git, "#status" do
  before :each do
    @tmpdir = Dir.mktmpdir
    Dir.chdir(@tmpdir) do
      `git init > /dev/null 2>&1`
      `git config user.email "test@example.com"`
      `git config user.name "Test User"`
      File.write("committed.txt", "committed line 1\ncommitted line 2\n")
      File.write("to_delete.txt", "delete me\n")
      `git add . && git commit -m initial > /dev/null 2>&1`
    end
  end

  after :each do
    FileUtils.remove_entry_secure @tmpdir if @tmpdir && File.directory?(@tmpdir)
  end

  it "lists categories when there are changes" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
      File.write("staged.txt", "staged line\n")
      `git add staged.txt`
      File.delete("to_delete.txt")
      File.write("untracked.txt", "untracked line\n")
    end

    res = Xiki::Menu::Git.status { {:dir => "#{@tmpdir}/"} }
    res.should == "+ commit/\n+ staged/\n+ modified/\n+ removed/\n+ untracked/\n"
  end

  it "only lists categories that have files along with commit" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
    end

    res = Xiki::Menu::Git.status { {:dir => "#{@tmpdir}/"} }
    res.should == "+ commit/\n+ modified/\n"
  end

  it "returns commit and clean message when no changes" do
    res = Xiki::Menu::Git.status { {:dir => "#{@tmpdir}/"} }
    res.should == "+ commit/\n| (no changes in working tree)\n"
  end

  it "lists files under staged, modified, removed, and untracked" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
      File.write("staged.txt", "staged line\n")
      `git add staged.txt`
      File.delete("to_delete.txt")
      File.write("untracked.txt", "untracked line\n")
    end

    # List staged
    res_staged = Xiki::Menu::Git.status("staged") { {:dir => "#{@tmpdir}/"} }
    res_staged.should == "+ staged.txt\n"

    # List modified
    res_mod = Xiki::Menu::Git.status("modified") { {:dir => "#{@tmpdir}/"} }
    res_mod.should == "+ committed.txt\n"

    # List removed
    res_rem = Xiki::Menu::Git.status("removed") { {:dir => "#{@tmpdir}/"} }
    res_rem.should == "+ to_delete.txt\n"

    # List untracked
    res_un = Xiki::Menu::Git.status("untracked") { {:dir => "#{@tmpdir}/"} }
    res_un.should == "+ untracked.txt\n"
  end

  it "shows options to stage, unstage, discard at each hunk" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
    end

    res = Xiki::Menu::Git.status("modified", "committed.txt") { {:dir => "#{@tmpdir}/"} }
    res.should include("+ stage\n+ unstage\n+ discard\n|@@ -1,2 +1,2 @@")
    res.should include("|-committed line 2")
    res.should include("|+line 2 changed")
  end

  it "shows +staged when hunk/file is staged" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
      `git add committed.txt`
    end

    res = Xiki::Menu::Git.status("staged", "committed.txt") { {:dir => "#{@tmpdir}/"} }
    res.should include("+ staged\n+ unstage\n+ discard\n|@@ -1,2 +1,2 @@")
  end

  it "shows options at each hunk in multi-hunk diffs" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", (1..30).map { |i| "line #{i}\n" }.join)
      `git add committed.txt && git commit -m multi > /dev/null 2>&1`
      lines = (1..30).map { |i| "line #{i}\n" }
      lines[4] = "line 5 MODIFIED\n"
      lines[24] = "line 25 MODIFIED\n"
      File.write("committed.txt", lines.join)
    end

    res = Xiki::Menu::Git.status("modified", "committed.txt") { {:dir => "#{@tmpdir}/"} }
    res.scan(/\+ stage\n\+ unstage\n\+ discard\n\|@@/).length.should == 2
  end

  it "stages, unstages, and discards a modified file interactively" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
    end

    # Stage
    stage_res = Xiki::Menu::Git.status("modified", "committed.txt", "stage") { {:dir => "#{@tmpdir}/"} }
    stage_res.should == "<* staged!"

    status_out = `cd #{@tmpdir} && git status --porcelain`
    status_out.should include("M  committed.txt")

    # Unstage
    unstage_res = Xiki::Menu::Git.status("staged", "committed.txt", "unstage") { {:dir => "#{@tmpdir}/"} }
    unstage_res.should == "<* unstaged!"

    status_out_after = `cd #{@tmpdir} && git status --porcelain`
    status_out_after.should include(" M committed.txt")

    # Discard
    discard_res = Xiki::Menu::Git.status("modified", "committed.txt", "discard") { {:dir => "#{@tmpdir}/"} }
    discard_res.should == "<* discarded!"

    status_out_clean = `cd #{@tmpdir} && git status --porcelain`
    status_out_clean.should_not include("committed.txt")
  end

  it "stages untracked file interactively" do
    Dir.chdir(@tmpdir) do
      File.write("new_file.txt", "some content\n")
    end

    stage_res = Xiki::Menu::Git.status("untracked", "new_file.txt", "stage") { {:dir => "#{@tmpdir}/"} }
    stage_res.should == "<* staged!"

    status_out = `cd #{@tmpdir} && git status --porcelain`
    status_out.should include("A  new_file.txt")
  end

  it "supports task option menu" do
    task_menu = Xiki::Menu::Git.status("modified", "committed.txt") { {:dir => "#{@tmpdir}/", :task => []} }
    task_menu.should == "* stage\n* unstage\n* discard"

    task_stage = Xiki::Menu::Git.status("modified", "committed.txt") { {:dir => "#{@tmpdir}/", :task => ["stage"]} }
    task_stage.should == "<* staged!"
  end

  it "shows commit in status when files are staged" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "committed line 1\nline 2 changed\n")
      `git add committed.txt`
    end

    res = Xiki::Menu::Git.status { {:dir => "#{@tmpdir}/"} }
    res.should include("+ commit/\n")
    res.should include("+ staged/\n")
  end

  it "renders commit template with option for large chunk of message" do
    res = Xiki::Menu::Git.commit { {:dir => "#{@tmpdir}/"} }
    res.should include("+ do commit/")
    res.should include("- enter message/")
    res.should include("| Type or paste your commit message below")
    res.should include("| Summary of changes")
    res.should include("| Detailed multi-line explanation of changes.")
  end

  it "commits single-line and large chunk multi-line commit messages" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "line 1\nline 2 updated\n")
      `git add committed.txt`
    end

    # Prompt message
    prompt_res = Xiki::Menu::Git.commit("enter message") { {:dir => "#{@tmpdir}/"} }
    prompt_res.should == "<? Enter commit message"

    # Large chunk commit
    large_msg = "| First line summary\n|\n| Large chunk of commit message paragraph 1.\n|\n| Paragraph 2 with details:\n| - Detail 1\n| - Detail 2\n"
    commit_res = Xiki::Menu::Git.commit(large_msg) { {:dir => "#{@tmpdir}/"} }
    commit_res.should include("<* committed!")

    log_out = `cd #{@tmpdir} && git log -1`
    log_out.should include("First line summary")
    log_out.should include("Large chunk of commit message paragraph 1.")
    log_out.should include("- Detail 1")
  end

  it "supports commit amend with reuse message, prompt, and large message" do
    Dir.chdir(@tmpdir) do
      File.write("committed.txt", "line 1\nline 2 amended\n")
      `git add committed.txt && git commit -m "Original message\n\nOriginal body" > /dev/null 2>&1`
      File.write("another.txt", "new file\n")
      `git add another.txt`
    end

    # Amend template
    amend_menu = Xiki::Menu::Git.commit("amend") { {:dir => "#{@tmpdir}/"} }
    amend_menu.should include("+ do amend/")
    amend_menu.should include("- reuse message/")
    amend_menu.should include("- enter message/")
    amend_menu.should include("| Original message")
    amend_menu.should include("| Original body")

    # Amend reuse message
    reuse_res = Xiki::Menu::Git.commit("amend", "reuse message") { {:dir => "#{@tmpdir}/"} }
    reuse_res.should include("<* amended!")
    log_out_reuse = `cd #{@tmpdir} && git log -1`
    log_out_reuse.should include("Original message")

    # Amend with edited multi-line message
    File.write("#{@tmpdir}/third.txt", "third file\n")
    `cd #{@tmpdir} && git add third.txt`

    amend_msg = "| Amended subject line\n|\n| Amended detailed description\n"
    amend_res = Xiki::Menu::Git.commit("amend", amend_msg) { {:dir => "#{@tmpdir}/"} }
    amend_res.should include("<* amended!")

    log_out_amend = `cd #{@tmpdir} && git log -1`
    log_out_amend.should include("Amended subject line")
    log_out_amend.should include("Amended detailed description")
  end
end



__END__

# Old test before moving to rspec:

#require 'test/unit'
#$:.unshift "../"
require 'ol'
require 'core_ext'
require 'yaml'
require 'git'

class GitTest < Test::Unit::TestCase

  @@status_raw = '
    # On branch master
    # Changes to be committed:
    #   (use "git reset HEAD <file>..." to unstage)
    #
    #	new file:   unadded.txt
    #	modified:   modified.rb
    #
    # Changed but not updated:
    #   (use "git add <file>..." to update what will be committed)
    #
    #	modified:   changed.rb
    #	modified:   modifiedandadded.rb
    #
    # Untracked files:
    #   (use "git add <file>..." to include in what will be committed)
    #
    #	untracked.rb
    #	untracked2.rb
    '.unindent

  @@status_parsed = '
    | On branch master
    | Changes to be committed:
    |   (use "git reset HEAD <file>..." to unstage)
    - new file: unadded.txt
    - modified: modified.rb
    | Changed but not updated:
    |   (use "git add <file>..." to update what will be committed)
    - modified: changed.rb
    - modified: modifiedandadded.rb
    | Untracked files:
    |   (use "git add <file>..." to include in what will be committed)
    - untracked.rb
    - untracked2.rb
    '.unindent

  @@status_parsed_only_new = '
    | On branch master
    | Initial commit
    | Untracked files:
    |   (use "git add <file>..." to include in what will be committed)
    - a.txt
    nothing added to commit but untracked files present (use "git add" to track)
    '.unindent

  # Should parse status initially
  def test_status_internal
    result = Git.status_internal @@status_raw
    assert_equal @@status_parsed, result
  end

  # Should parse status into hash of arrays
  def test_status_to_hash

    # Parse it
    hash = Git.status_to_hash @@status_parsed

    assert hash[:unadded]
    assert_equal [
      ['modified', 'changed.rb'],
      ['modified', 'modifiedandadded.rb']],
      hash[:unadded]

    assert hash[:added]
    assert_equal [
      ['new file', 'unadded.txt'],
      ['modified', 'modified.rb']],
      hash[:added]

    assert hash[:untracked]
    assert_equal [
      ['untracked', 'untracked.rb'],
      ['untracked', 'untracked2.rb']],
      hash[:untracked]
  end

  # Should handle only new
  def test_status_to_hash_only_new
    # Parse it
    hash = Git.status_to_hash @@status_parsed_only_new

    assert hash[:untracked]
  end

end
