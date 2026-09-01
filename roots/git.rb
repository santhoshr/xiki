require 'xiki/core/core_ext' if ! defined?(CoreExt)
require 'xiki/core/bookmarks' if ! defined?(Xiki::Bookmarks)
require 'xiki/core/shell' if ! defined?(Xiki::Shell)
require 'xiki/core/tree' if ! defined?(Xiki::Tree)
require 'xiki/core/git' if ! defined?(Xiki::Git)

module Xiki
  module Menu
    class Git

    @@git_diff_options = '-U2'

    MENU = "
      - .diff/
      - .status/
      - .commit/
      - .log/
      - .graph/
      - .setup/
        - .create/
        - .make sample files/
        - github/
          - Make this run in first dir it finds above!
          @% git remote add origin git@github.com:myusername/foo.git
      - .docs/
      "

    MENU_HIDDEN = "
      - .push/
      - .diff/
        - .commit/
        - .add/
        - .remove/
        - .revert/
        - .unadd/
      - .status/
        - .stage/
        - .unstage/
        - .discard/
        - .staged/
        - .commit/
          - .amend/
        - .remove/
        - .revert/
      - .commit/
        - .amend/
      "

    def self.menu_before *args

      return if ['docs', 'do push'].member?(args[0])

      options = yield

      dir = options[:dir]

      exists, kind = FileTree.examine dir   # => [false, :file]

      # If file/dir doesn't exist, suggest creating

      if ! exists
        return "| File '#{dir}' doesn't exist" if kind == :file
        return FileTree.suggest_mkdir dir
      end

      branch = Xiki::Git.branch_name dir   #> |||

      # If not a repo, suggest creating one...
      if args[0] != "setup" && branch.nil?
        return "| Not a git repository.  Create a new one here?\n- setup/create/"
      end

      nil
    end

    def self.menu_after output, *args

      return if args.any?

      # If /, add push/thebranch/ to the beginning

      branch = Xiki::Git.branch_name
      "+ push/#{branch}/\n#{output}"
    end

    def self.diff *args

      options = yield
      options[:no_search] = 1

      options[:no_slash] = 1

      dir = options[:dir]

      quote = args.pop if args[-1] =~ /^\|/
      quote = args.pop if args[-1] =~ /^:/
      path = args.any? ? args.join("/") : nil
      quote = quote.sub(/^:/, '') if quote

      # If we're nested under a file, break up into parts
      if File.file? dir
        dir, path = Xiki::Git.toplevel_split dir
      end

      self.git_diff dir, path, quote, options
    end


    def self.status_files dir=nil
      raw = Shell.command("git status --porcelain -uall", :dir=>dir)

      added = []
      modified = []
      removed = []
      untracked = []

      raw.each_line do |line|
        line = line.chomp
        next if line.empty?
        x = line[0]
        y = line[1]
        file = line[3..-1]
        next unless file

        # Staged in index (added)
        if ['A', 'M', 'D', 'R', 'C'].include?(x)
          added << file
        end

        # Working tree modified (unstaged)
        if y == 'M'
          modified << file
        end

        # Removed / deleted (unstaged deletion or staged deletion)
        if y == 'D' || x == 'D'
          removed << file
        end

        # Untracked
        if x == '?' && y == '?'
          untracked << file
        end
      end

      {
        :staged => added.uniq.sort,
        :added => added.uniq.sort,
        :modified => modified.uniq.sort,
        :removed => removed.uniq.sort,
        :untracked => untracked.uniq.sort,
      }
    end

    def self.status *args

      options = yield if block_given?
      options ||= {}
      dir = options[:dir] || Tree.closest_dir

      files = self.status_files dir

      # /status (no args), list commit and categories that contain files...
      if args.empty?
        categories = ["+ commit/\n"]
        categories << "+ staged/\n" if files[:staged].any?
        categories << "+ modified/\n" if files[:modified].any?
        categories << "+ removed/\n" if files[:removed].any?
        categories << "+ untracked/\n" if files[:untracked].any?

        if files.values.all?(&:empty?)
          categories << "| (no changes in working tree)\n"
        end

        return categories.join
      end

      category = args.shift
      category = "staged" if category == "added"

      if category == "commit"
        return self.commit(*args) { options }
      end

      # Handle legacy label like "modified: foo.txt" or raw file
      if !["staged", "modified", "removed", "untracked"].include?(category)
        args.unshift category
        category = nil
      end

      # /status/<category>/, list files under that category...
      if args.empty?
        cat_files = files[category.to_sym] || []
        if cat_files.empty?
          return "| No #{category} files\n"
        end
        return cat_files.map { |f| "+ #{f}\n" }.join
      end

      # /status/<category>/<file>/...

      # If last arg is a diff line (|... or :...), jump to file in tree
      if args.last =~ /^[|:]/
        args.pop
        file = args.join("/")
        file.sub!(/.+ -> /, "")
        whole_path = "#{dir}#{file}"
        self.jump_to_file_in_tree whole_path
        return nil
      end

      # If an action was chosen (stage, unstage, discard, staged, add, revert, remove)
      if ["stage", "unstage", "discard", "staged", "add", "revert", "remove"].include?(args.last)
        action = args.pop
        file = args.join("/")
        file.sub!(/.+ -> /, "")
        return self.tasks_item [action], file, dir
      end

      # If options[:task] is set (invoked via task menu)
      task = options[:task]
      if task == []
        return "* stage\n* unstage\n* discard"
      elsif task
        file = args.join("/")
        file.sub!(/.+ -> /, "")
        return self.tasks_item task, file, dir
      end

      # File expanded: show options and diff formatted at each hunk
      file = args.join("/")
      file.sub!(/.+ -> /, "")

      diff_txt = ""

      if category == "staged" || category == "added"
        command = "git diff --cached #{self.git_diff_options} --patience --relative -- \"#{file}\""
        diff_txt, error = self.diff_internal command, dir
        if diff_txt.blank? && File.file?("#{dir}#{file}")
          content = File.read("#{dir}#{file}") rescue ""
          diff_txt = "@@ +1\n" + content.lines.map { |l| "+#{l}" }.join
        end
        return self.format_hunks diff_txt, true
      elsif category == "modified"
        command = "git diff #{self.git_diff_options} --patience --relative -- \"#{file}\""
        diff_txt, error = self.diff_internal command, dir
        return self.format_hunks diff_txt, false
      elsif category == "removed"
        command = "git diff #{self.git_diff_options} --patience --relative -- \"#{file}\""
        diff_txt, error = self.diff_internal command, dir
        is_staged = false
        if diff_txt.blank?
          command = "git diff --cached #{self.git_diff_options} --patience --relative -- \"#{file}\""
          diff_txt, error = self.diff_internal command, dir
          is_staged = true if diff_txt.present?
        end
        if diff_txt.present?
          return self.format_hunks diff_txt, is_staged
        else
          show_txt = Shell.command("git show HEAD:\"#{file}\"", :dir=>dir) rescue ""
          if show_txt.present?
            diff_txt = "@@ -1\n" + show_txt.lines.map { |l| "-#{l}" }.join
            return self.format_hunks diff_txt, is_staged
          end
        end
      elsif category == "untracked"
        if File.file?("#{dir}#{file}")
          content = File.read("#{dir}#{file}") rescue ""
          diff_txt = "@@ +1\n" + content.lines.map { |l| "+#{l}" }.join
          return self.format_hunks diff_txt, false
        end
      else
        command = "git diff #{self.git_diff_options} --patience --relative -- \"#{file}\""
        diff_txt, error = self.diff_internal command, dir
        is_staged = false
        if diff_txt.blank?
          command = "git diff --cached #{self.git_diff_options} --patience --relative -- \"#{file}\""
          diff_txt, error = self.diff_internal command, dir
          is_staged = true if diff_txt.present?
        end
        if diff_txt.present?
          return self.format_hunks diff_txt, is_staged
        elsif File.file?("#{dir}#{file}")
          content = File.read("#{dir}#{file}") rescue ""
          diff_txt = "@@ +1\n" + content.lines.map { |l| "+#{l}" }.join
          return self.format_hunks diff_txt, false
        end
      end

      self.format_hunks diff_txt, false
    end

    def self.format_hunks diff_txt, is_staged=false
      return "| (no diff)\n" if diff_txt.nil? || diff_txt.strip.empty?

      hunk_options = is_staged ? "+ staged\n+ unstage\n+ discard\n" : "+ stage\n+ unstage\n+ discard\n"

      diff_txt = diff_txt.sub(/.*?^(@@ )/m, "\\1")
      return "| (no diff)\n" unless diff_txt =~ /^@@ /

      hunk_chunks = diff_txt.split(/^(?=@@ )/)

      formatted_hunks = hunk_chunks.map do |chunk|
        self.clean! chunk
        quoted_chunk = chunk.lines.map do |line|
          line =~ /^\|/ ? line : "|#{line}"
        end.join
        "#{hunk_options}#{quoted_chunk}"
      end

      formatted_hunks.join
    end

    def self.tasks_item task, file, dir

      if task == ["stage"] || task == ["add"]
        command = "git add -- \"#{file}\""
        txt = Shell.sync command, :dir=>dir
        return Tree.quote(txt) if txt.any?
        return "<* staged!"
      end

      if task == ["unstage"] || task == ["unadd"]
        command = "git reset HEAD -- \"#{file}\""
        txt = Shell.sync command, :dir=>dir
        if txt =~ /fatal: ambiguous argument 'HEAD'/
          txt = Shell.sync "git reset -- \"#{file}\"", :dir=>dir
        end
        return Tree.quote(txt) if txt =~ /^fatal:/
        return "<* unstaged!"
      end

      if task == ["discard"] || task == ["revert"]
        Shell.sync "git reset HEAD -- \"#{file}\"", :dir=>dir rescue nil
        command = "git checkout HEAD -- \"#{file}\""
        txt = Shell.sync command, :dir=>dir
        if txt =~ /fatal:/ || txt =~ /error:/
          txt = Shell.sync "git checkout -- \"#{file}\"", :dir=>dir
        end
        return "<* discarded!"
      end

      if task == ["staged"]
        return "<* already staged!"
      end

      if task == ["add multiple"]
        indent = Line.indent
        Line.to_left
        View.<< "#{indent}+ add/\n", :dont_move=>1
        return ""
      end

      if task == ["remove"]
        command = "git rm -r -- \"#{file}\""
        txt = Shell.sync command, :dir=>dir
        return "<* removed!"
      end

    end


    def self.status_raw
      dir = options[:dir]

      result = Shell.sync "echo 'TODO - finish .status_raw - #{dir}'"
      Tree.quote result
    end

    def self.make_sample_files
      options = yield
      dir = options[:dir]

      Dir.mkdir "#{dir}d" rescue nil

      txt = "hello\nhi again\n"
      filenames = ["a.txt", "b.txt", "d/aa.txt"]

      filenames.each { |path| File.open("#{dir}#{path}", "w") { |f| f << txt } }

      Shell.command "git add #{filenames.join ' '}", :dir=>dir

      "
      | Created and added these files:
      | - a.txt
      | - b.txt
      | - d/
      |   - aa.txt
      "
    end

    def self.if_not_repository branch
      return nil if branch   # Fine if there's a branch

      Xiki.quote "
        > Not a repository
        This dir isn't a git repository.
        |
        > Create a repository?
        - setup/create/
        "
    end

    def self.push branch

      # If no branch, use default
      if branch.nil?
        return "- choose the branch!"
      end

      options = yield
      dir = options[:dir]

      self.push_internal branch, dir

      nil
    end

    def self.add # options=nil
      options = yield
      dir = options[:dir]

      siblings = Tree.siblings

      siblings = self.remove_options siblings
      return "- No files to add (they should be siblings of add)!" unless siblings.any?

      command = "git add #{siblings.join("\\\n  ")}"

      txt = Shell.sync command, :dir=>dir
      return Tree.quote(txt) if txt.any?
      "<* added!"
    end

    def self.commit *args
      options = yield if block_given?
      options ||= {}
      dir = options[:dir] || Tree.closest_dir

      # /commit (no args), so show template for commit message
      if args.empty?
        files = self.status_files dir
        warning = files[:staged].empty? ? "| Note: nothing staged to commit yet. Stage files first with + stage\n|\n" : ""
        return "
          #{warning}+ do commit/
          - enter message/
          + amend/
          | Type or paste your commit message below, then expand '+ do commit/':
          |
          | Summary of changes
          |
          | Detailed multi-line explanation of changes.
          ".unindent
      end

      is_amend = false

      if args[0] == "amend"
        args.shift
        is_amend = true
        if args.empty?
          last_msg = Shell.command("git log -1 --pretty=format:%B", :dir=>dir) rescue ""
          last_msg = "Amended commit message\n" if last_msg.blank?
          quoted_last_msg = last_msg.lines.map { |l| l.chomp.empty? ? "|\n" : "| #{l.chomp}\n" }.join
          return "
            + do amend/
            - reuse message/
            - enter message/
            | Edit your amend commit message below, then expand '+ do amend/':
            |
            #{quoted_last_msg}
            ".unindent
        end
      end

      if args[0] == "reuse message"
        txt, error = Shell.command "git commit --amend --no-edit", :dir=>dir, :return_error=>1
        if error && !error.empty? && (txt.nil? || txt.empty?)
          return "| Error amending:\n" + error.lines.map { |l| "| #{l}" }.join
        end
        res = (txt && !txt.empty?) ? txt : "Amended!"
        return "<* amended!\n" + res.lines.map { |l| "| #{l}" }.join
      end

      if args[0] == "do amend"
        is_amend = true
        args.shift
        # Grab sibling lines from the buffer
        siblings = Tree.siblings(:cross_blank_lines=>1) rescue []
        msg_lines = siblings.select { |l| l =~ /^\|/ }.map { |l| l.sub(/^\| ?/, '') }
        message = msg_lines.join("\n") if msg_lines.any?
      end

      if args[0] == "enter message"
        if args.length == 1
          return is_amend ? "<? Enter amend commit message" : "<? Enter commit message"
        else
          message = args[1..-1].join("/")
        end
      elsif args[0] == "do commit"
        # Grab sibling lines from the buffer
        siblings = Tree.siblings(:cross_blank_lines=>1) rescue []
        msg_lines = siblings.select { |l| l =~ /^\|/ }.map { |l| l.sub(/^\| ?/, '') }
        message = msg_lines.join("\n") if msg_lines.any?
      end

      if message.blank?
        message = args.join("\n")
      end

      message = message.lines.reject { |l| l =~ /Type (or paste )?(your )?commit message below/i || l =~ /Edit (your )?amend commit message below/i || l =~ /Or insert commit message below/i || l =~ /Note: nothing staged/i }.join
      message.gsub!(/^\| ?/, '')
      message.strip!

      return is_amend ? "<? Enter amend commit message" : "<? Enter commit message" if message.blank?

      cmd = is_amend ? "git commit --amend -F -" : "git commit -F -"
      txt, error = Shell.command cmd, :dir=>dir, :stdin=>message, :return_error=>1

      if error && !error.empty? && (txt.nil? || txt.empty?)
        action_name = is_amend ? "amending" : "committing"
        return "| Error #{action_name}:\n" + error.lines.map { |l| "| #{l}" }.join
      end

      action_past = is_amend ? "amended" : "committed"
      res = (txt && !txt.empty?) ? txt : "#{action_past.capitalize}!"
      "<* #{action_past}!\n" + res.lines.map { |l| "| #{l}" }.join
    end

    def self.methods_by_date path
      txt = Shell.sync "git blame \"#{path}\""
      txt = txt.split "\n"

      txt = txt.select{|o| o =~ /\) *def /}   # Remove all but method definitions
      txt.sort!{|a, b| a[/....-..-.. ..:..:../] <=> b[/....-..-.. ..:..:../]}   # Sort by date
      txt.each{|o| o.sub! /.+?\) /, ''}
      txt = txt.reverse
    end



    # Moved over from gito.rb - some of this can probably be deleted...



    def self.diff_internal command, dir, options={}

      txt, error = nil, nil
      if options[:txt]
        txt = options[:txt]
      else
        txt, error = Shell.command command, :dir=>dir, :return_error=>1
      end

      return ["", error] if error

      # Show intra-line diffs > not used any more
      if Keys.prefix_u
        txt.gsub!(/\c[\[31m(.*?)\c[\[m/, "\(\-\\1\-\)")
        txt.gsub!(/\c[\[32m(.*?)\c[\[m/, "\(\+\\1\+\)")
        txt.gsub!(/\c[\[\d*m/, '')
        txt.gsub!("\-\)\(\-", '')   # Merge adjacent areas
        txt.gsub!("\+\)\(\+", '')
        txt.gsub!(/^./, " \\0")   # Add space at beginning of all non-blank lines
        txt.gsub!(/^ @/, '@')
        # Find whole lines
        txt.gsub!(/^ \(\+(.*)\+\)$/) {|m| $1.index("\(\+") ? m : "+#{$1}" }
        txt.gsub!(/^ \(\-(.*)\-\)$/) {|m| $1.index("\(\-") ? m : "-#{$1}" }
        # Remove empty (--)'s
        txt.gsub! /\([+-][+-]\)/, ''
      else
        txt.gsub! /^ $/, ''
        # Delete redundant lines and format some as gray
        txt.gsub! /^new file mode .+\n/, ""
        txt.gsub! /^deleted file mode /, "@@ \\0"
      end

      [txt, error]
    end

    def self.graph *args
      options = yield
      dir = options[:dir]

      txt = Shell.sync %`git log --graph --full-history --all --pretty=format:"%h%x09%d%x20%s"`, :dir=>dir

      Tree.quote txt
    end

    def self.log *args
      options = yield

      dir = options[:dir]

      toplevel, relative = Xiki::Git.toplevel_split dir

      rev, *file_and_line = args

      # search=nil, project=nil, rev=nil, *file_and_line

      prefix = options[:prefix]

      # /, so list all revs...

      if rev.nil?

        command = "git log --follow -1000 --oneline"
        command << " '#{relative}'" if relative
        txt = Shell.command command, :dir=>toplevel

        return "> No revisions in the repository yet?\n: It looks like this is a new repository. Do a commit first,\n: then try running 'log' again." if txt == "\n> error\nfatal: bad default revision 'HEAD'\n"

        txt.gsub! ':', '-'
        txt.gsub! /(.+?) (.+)/, "\\2) \\1/"
        txt.gsub! /^- /, ''

        return txt.gsub!(/^/, '+ ')
      end

      # I think this is merging together items/wish/slashes
      line = file_and_line.pop if file_and_line.last =~ /^\|/
      file = file_and_line.any? ? file_and_line.join('/') : nil

      # If /file.txt/@git/log/, it's the only one to choose, so short-circuit
      is_file = File.file? dir
      if is_file
        file = relative
      end


      # /rev/, so show files for rev...

      if ! file

        relative_flag = relative ? "--relative=#{relative}" : ''
        command = "git diff --pretty=oneline --name-status #{relative_flag} #{rev}~ #{rev}"

        # Rev passed, so show all diffs
        txt, error = self.diff_internal command, toplevel

        txt.gsub! /^([A-Z]+)\t/, "\\1) "
        txt.gsub! /^M\) /, ''
        return txt.split("\n").sort.map{|l| "+ #{l}\n"}.join('')
      end

      if ! is_file   # If dir
        file = "#{relative}/#{file}" if relative
      end

      # /rev/file, so diff...

      if line.empty?

        options[:no_slash] = 1

        if prefix == "all" || prefix == 0

          # If enter+all, show just contents, not diff
          # Probably broken - hasn't been tested since Unified refactor

          minus_one = prefix == 0 ? "~" : ""
          txt = Shell.run("git show #{rev}#{minus_one}:#{file}", :sync=>true, :dir=>toplevel)

          return Tree.quote txt
        end

        command = "git show #{@@git_diff_options} --pretty=oneline #{rev} -- #{file}"

        txt, error = self.diff_internal command, toplevel
        txt.sub!(/.+?@@/m, '@@')
        txt.gsub! /^/, '|'

        return txt
      end

      # /rev/file/line, so jump to file...

      whole_path = is_file ? dir : "#{toplevel}/#{file}"

      self.jump_to_file_in_tree whole_path
      nil
    end

    def self.show_log
      dir = Keys.bookmark_as_path :prompt=>"Enter a bookmark to show the log for: "

      Launcher.open("#{dir}/@git/log//")
    end

    def self.jump_to_file_in_tree file

      # TODO: decouple from editor
      #   - probably do cursor stuff conditionally, if $el
      #     - pass in other params so it'll work in web interface

      # TODO: Getting ancestors is probably a better approach

      orig = View.cursor

      Search.backward "^ +[|:]@@" unless Line.matches(/^ +[|:]@@/)
      inbetween = View.txt(orig, View.cursor)
      inbetween.gsub!(/^ +[|:]-.*\n/, '')
      inbetween = inbetween.count("\n")
      line = Line.value[/\+(\d+)/, 1]

      View.cursor = orig

      View.open file
      View.to_line(line.to_i + (inbetween - 1))
    end

    def self.clean! txt
      txt.gsub!(/^ ?index .+\n/, '')
      txt.gsub!(/^ ?--- .+\n/, '')
      txt.gsub!(/^ ?\+\+\+ .+\n/, '')
    end

    def self.git_diff dir, file, line, options={}

      is_unadded = false   # This is now hard-coded. It used to enable a mode for bypassing adding and commtting directly?

      # /, so show diff of files...

      if file.nil?
        txt = Shell.command "git status --porcelain", :dir=>dir
        hash = Xiki::Git.status_to_hash txt

        untracked = hash[:untracked]

        untracked.map!{|i| "+ untracked) #{i[1]}\n"}

        option = is_unadded ? "- add\n" : "- commit/\n"
        command = "git diff -b --patience --relative #{self.git_diff_options} #{is_unadded ? '' : ' HEAD'}"

        is_file = File.file? dir

        txt, error = self.diff_internal command, dir

        if error =~ /^fatal: ambiguous argument 'HEAD': unknown revision/
          txt = self.status_hash_to_bullets hash, is_unadded
        else
          unless txt.empty?

            self.clean! txt
            txt.gsub!(/^/, '  :')

            if is_file
              return txt.sub(/.+\n/, '')   # First "diff..." line deleted
            end

            txt.gsub!(/^  : ?diff --git .+ b\//, '- ')
          end
        end

        # Add labels back
        if is_unadded   # If unadded, add labels from added (if they exist there)
          hash[:added].each {|i| txt.sub! /^([+-]) #{i[1]}$/, "\\1 #{i[0]}) #{i[1]}"}
        else   # If added, add your label also unadded (or special)
          unadded = hash[:unadded].map{|i| i[1]}
          hash[:added].each do |i|
            # Only add label if file is also unadded, or if label isn't 'modified'
            next unless unadded.member?(i[1]) or i[0] != 'modified'
            txt.sub! /^([+-]) #{i[1]}$/, "\\1 #{i[0]}) #{i[1]}"
          end
        end

        # No files in project, so suggest they create some...

        if Dir["#{dir}*"] == []
          return "
            | No files exist. Try creating some and adding them to the repo.
            |
            | This creates and adds a few sample files automatically:
            =git/setup/make sample files/
          ".unindent
        end

        txt << untracked.join("") if untracked

        return "
          | There were no differences to added files. Try modifying some files first,
          | or adding some unadded files.
          ".unindent if ! txt.any?

        return option + txt + "
          - add/
          - delete/
          - revert/
          - unadd/
          ".unindent
      end

      # /file, so show diff...

      if line.nil?   # If no line passed, re-do diff for 1 file

        txt, error = is_unadded ?
          self.diff_internal("git diff --patience --relative #{self.git_diff_options} #{file}", dir) :
          self.diff_internal("git diff --patience -b --relative #{self.git_diff_options} HEAD #{file}", dir)

        # File doesn't exist in repo, so just show its contents...

        if error =~ /^fatal: ambiguous argument 'HEAD'/
          txt = File.read "#{dir}#{file}"
          txt.gsub! /^/, ' '
        end

        self.clean! txt

        if txt.blank?
          file_in_repository = self.file_in_repository? dir, file

          # If not in repository, just show the contents
          if ! file_in_repository
            return "| untracked file:\n|@@ +1\n" + File.read(Bookmarks.expand("#{dir}/#{file}")).gsub(/^/, '|+').gsub("\c@", '.')
          end
          return "| No diffs"
        end

        txt.gsub!(/^ ?diff .+\n/, '')
        txt.gsub!(/^/, ':')

        self.jump_line_number_maybe txt, options

        return txt
      end

      # /file/line, so navigate to file...

      whole_path = "#{dir}/#{file.sub(/\/$/, '')}"

      # If line passed, jump to it
      self.jump_to_file_in_tree whole_path
      nil
    end

    def self.jump_line_number_maybe txt, options

      line_found = options.delete :line_found
      return if ! line_found

      # Get rid of this?  What did it do?  Possibly an early version of the diff where I made the line numbers parents items?
      last = 0

      target_line, target_boundary = 0, 0
      txt.split("\n").each_with_index do |o, i|
        target_line += 1 if o =~ /^:[+ ]/
        match = o[/^:@@ .+\+(\d+)/, 1]
        if target_line >= line_found
          break
        end
        if match
          target_boundary = target_line = match.to_i
          last = i
        end
      end
      last += 3
      last += (target_line - target_boundary)

      options[:line_found] = last
    end


    def self.status_hash_to_bullets hash, is_unadded
      if is_unadded   # If unadded, simply use unadded
        return hash[:unadded].map{|i| "+ #{i[1]}\n"}.join('')
      end

      txt = (hash[:unadded].map{|i| "+ #{i[1]}\n"} +
        hash[:added].map{|i| "+ #{i[1]}\n"}).sort.uniq.join('')
    end

    def self.push_internal dest, dir

      # Todo > only cd if necessary!

      DiffLog.quit_and_run "cd \"#{dir}\"\ngit push origin #{dest}"

      nil
    end

    def self.remove_options siblings
      siblings = siblings.map{|l| l.sub /^[+-] /, ""}
      siblings.map!{|l| l.sub /^[a-z ]+: /, ""}
      siblings = siblings.select{|o| o !~ /^(commit|delete|revert|add|unadd|remove)\// && o =~ /^\w/}
      siblings.map!{|o| o.sub(/^(modified|deleted|renamed): /, '')}
      siblings.map!{|o| o.sub(/^new file\) /, '')}
      siblings
    end

    def self.commit_internal message, dir

      siblings = Tree.siblings :include_label=>true
      # Remove labels

      # Remove "untracked (ignore)"
      siblings = self.remove_options siblings

      unless siblings.any?   # Error if no siblings
        return "<* Provide some files (on lines next to this menu, with no blank lines, and no untracked files)!"
      end

      siblings = siblings.map{|o| "\"#{o}\""}.join(" ")
      siblings.gsub!(" -> ", "\" \"")   # In case any "a -> b" exist, from renames

      # Todo > only cd if necessary!

      DiffLog.quit_and_run "cd \"#{dir}\"\ngit commit -m \"#{message}\" #{siblings}"

    end

    def self.unadd

      dir = options[:dir]

      siblings = Tree.siblings :include_label=>true
      siblings.map!{|i| Line.without_label(:line=>i)}
      siblings = self.remove_options siblings

      return "- No files to unadd (they should be siblings of unadd)!" if siblings.empty?   # Error if no siblings

      command = "git reset #{siblings.join(' ')}"
      txt = Shell.sync command, :dir=>dir
      return Tree.quote txt if txt.any?
      "<* unadded!"
    end

    def self.revert

      dir = options[:dir]

      siblings = Tree.siblings :include_label=>true
      siblings.map!{|i| Line.without_label(:line=>i)}
      siblings = self.remove_options siblings

      return "- No files to revert (they should be siblings of revert)!" if siblings.empty?   # Error if no siblings

      command = "git checkout #{siblings.join(' ')}"
      txt = Shell.sync command, :dir=>dir
      return Tree.quote txt if txt.any?
      "<* reverted!"
    end

    def self.remove
      options = yield
      dir = options[:dir]

      siblings = Tree.siblings :include_label=>true
      siblings.map!{|i| Line.without_label(:line=>i)}
      siblings = self.remove_options siblings

      return "- No files to unadd (they should be siblings of delete)!" if siblings.empty?   # Error if no siblings

      command = "git rm #{siblings.map{|o| "\"#{o}\""}.join(' ')}"   # "
      txt = Shell.sync command, :dir=>dir
      return Tree.quote txt if txt.any?
      "<* deleted!"
    end

    def self.git_diff_options
      @@git_diff_options + (Keys.prefix_u ? ' --color-words' : '')
    end

    def self.search_just_push
      match = Search.stop

      # .code_tree_diff was deprecated in Unified refactor - see do+push
      self.code_tree_diff
      View.to_highest

      Search.isearch match
    end

    # Meant to search git diffs.
    def self.search_repository
      self.code_tree_diff
    end

    def self.create

      options = yield
      dir = options[:dir]
      result = Shell.sync 'git init', :dir=>dir
      "
      | #{result.strip}
      |
      | Now re-expand the \"git\" command.
      "
    end

    def self.file_in_repository? dir, file
      txt = Shell.sync "git ls-files '#{file}'", :dir=>dir
      txt.any?   # It's in the repository if it didn't return blank
    end

    end
  end
end
