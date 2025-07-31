-- code bridge neovim plugin
local M = {}

-- Track the chat buffer and window during the session
local chat_buffer = nil
local chat_window = nil
local running_process = nil

-- Build context string with filename and range
local function build_context(opts)
  local context = ''
  local relative_file = vim.fn.expand('%')

  if relative_file ~= '' then
    if opts.range == 2 then
      -- Visual mode - use the range from command
      context = '@' .. relative_file .. '#L' .. opts.line1 .. '-' .. opts.line2
    else
      -- Normal mode - just file name, no line number
      context = '@' .. relative_file
    end
  end

  return context
end

-- Send filename and position to tmux claude window (or copy to clipboard if unavailable)
M.send_to_claude_tmux = function(opts)
  local context = build_context(opts)

  if context == '' then
    print("no file context available")
    return
  end

  -- Always copy to clipboard (helpful in case claude code vim mode is not in insert mode)
  vim.fn.setreg('+', context)

  -- Check shell error and fallback to clipboard if needed
  local function check_shell_error(message)
    if vim.v.shell_error == 0 then
      return false
    end
    print(message .. ", copied to clipboard: " .. context)
    return true
  end

  -- Check if we're in a tmux session
  vim.fn.system('tmux display-message -p "#{session_name}" 2>/dev/null')
  if check_shell_error("no tmux session") then return end

  local target_window = nil
  local is_claude_session = false

  -- First, check if claude window exists in current session
  vim.fn.system('tmux list-windows -F "#{window_name}" 2>/dev/null | grep -x claude')
  if vim.v.shell_error == 0 then
    target_window = 'claude'
  else
    -- Check if a scratch session exists with claude window
    vim.fn.system('tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -x scratch')
    if vim.v.shell_error == 0 then
      -- Find the first window in the claude session
      local claude_window = vim.fn.system('tmux list-windows -t scratch -F "#{window_name}" 2>/dev/null | head -1'):gsub(
        '%s+$', '')
      if claude_window ~= '' then
        target_window = 'scratch:' .. claude_window
        is_claude_session = true
      end
    end
  end

  if not target_window then
    check_shell_error('no claude window found')
    return
  end

  -- Send context to claude window/session
  vim.fn.system('tmux send-keys -t ' ..
    vim.fn.shellescape(target_window) .. ' ' .. vim.fn.shellescape(context) .. ' Enter')
  if check_shell_error("failed to send to claude") then return end

  -- Switch to claude window or recreate popup for claude session
  if is_claude_session then
    vim.fn.system('tmux popup -w 80% -h 80% -b rounded -E "tmux attach-session -t scratch"')
    if vim.v.shell_error ~= 0 then
      print("sent to claude but failed to create popup - please check manually")
    end
  else
    vim.fn.system('tmux select-window -t ' .. vim.fn.shellescape(target_window))
    if vim.v.shell_error ~= 0 then
      print("sent to claude but failed to switch window - please check manually")
    end
  end
end

-- Query Claude Code using its CLI option and show results in chat pane
M.claude_query = function(opts)
  local include_context = opts.args ~= 'no-context'
  local context = include_context and build_context(opts) or ''
  local thinking_message = '## Thinking...'

  -- Check if chat is already thinking
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    local current_lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
    if #current_lines > 0 and current_lines[#current_lines] == thinking_message then
      print("please wait - thinking...")
      return
    end
  end

  -- Prompt for user input
  local message = vim.fn.input('chat: ')
  if message == '' then
    return
  end

  -- Combine context and message
  local full_message = context ~= '' and (context .. ' ' .. message) or message

  -- Track the original window to return to it later
  local original_win = vim.api.nvim_get_current_win()
  local is_reuse = false
  local buf

  -- Check if chat buffer and window exist
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    if chat_window and vim.api.nvim_win_is_valid(chat_window) then
      -- Window exists, just switch to it
      vim.api.nvim_set_current_win(chat_window)
      buf = chat_buffer
      is_reuse = true
    else
      -- Buffer exists but window doesn't, create new window
      vim.cmd('rightbelow vsplit')
      vim.api.nvim_win_set_buf(0, chat_buffer)
      chat_window = vim.api.nvim_get_current_win()
      buf = chat_buffer
      is_reuse = true
      vim.bo[chat_buffer].bufhidden = 'wipe'
    end
  else
    -- Create new buffer and split window
    vim.cmd('rightbelow vsplit')
    vim.cmd('enew')

    -- Save in local variables for reuse
    buf = vim.api.nvim_get_current_buf()
    chat_buffer = buf
    chat_window = vim.api.nvim_get_current_win()

    -- Set buffer options
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_name(buf, 'Chat')
    vim.wo.wrap = true
    vim.wo.linebreak = true

    -- Set up autocommand to clean up when buffer is wiped
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      callback = function()
        -- Terminate running process if exists
        if running_process then
          running_process:kill()
          running_process = nil
        end
        chat_buffer = nil
        chat_window = nil
      end
    })
  end

  -- Prepare the query lines
  local query_lines = { '# Query', full_message, '', thinking_message }

  -- Add a separator if continuing an existing chat
  if is_reuse then
    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local separator = { '', '-------------------------------------', '' }
    vim.list_extend(current_lines, separator)
    vim.list_extend(current_lines, query_lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
    local buf_window = vim.fn.bufwinid(buf)
    if buf_window ~= -1 then
      vim.api.nvim_win_set_cursor(buf_window, { #current_lines, 0 })
    end
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, query_lines)
  end

  -- Return focus to original window
  vim.api.nvim_set_current_win(original_win)

  -- Set command based on new or existing chat
  local cmd_args = is_reuse and { 'claude', '-c', '-p', full_message } or { 'claude', '-p', full_message }

  -- Execute the command asynchronously
  running_process = vim.system(cmd_args, {}, function(result)
    vim.schedule(function()
      running_process = nil

      if vim.api.nvim_buf_is_valid(buf) then
        local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        -- Find and replace the last waiting message
        for i = #current_lines, 1, -1 do
          if current_lines[i] == thinking_message then
            current_lines[i] = '# Response'
            break
          end
        end

        -- Check for errors
        local output_text = result.stdout or 'No output received'
        if result.stderr and result.stderr ~= '' then
          output_text = 'Error: ' .. result.stderr
        end

        -- Add the response
        local lines = vim.split(output_text, '\n')
        vim.list_extend(current_lines, lines)

        -- Update the buffer
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)

        -- Scroll to bottom if window is valid
        if chat_window and vim.api.nvim_win_is_valid(chat_window) then
          vim.api.nvim_win_set_cursor(chat_window, { #current_lines, 0 })
        end
      end
    end)
  end)
end

-- Hide chat buffer without clearing it
M.hide_chat = function()
  if chat_window and vim.api.nvim_win_is_valid(chat_window) then
    -- Change bufhidden to prevent wiping when window closes
    if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
      vim.bo[chat_buffer].bufhidden = 'hide'
    end
    vim.api.nvim_win_close(chat_window, false)
    chat_window = nil
  end
end

-- Show chat buffer if it exists
M.show_chat = function()
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    if chat_window and vim.api.nvim_win_is_valid(chat_window) then
      -- Window exists, just focus on it
      vim.api.nvim_set_current_win(chat_window)
    else
      -- Buffer exists but window doesn't, create new window
      vim.cmd('rightbelow vsplit')
      vim.api.nvim_win_set_buf(0, chat_buffer)
      chat_window = vim.api.nvim_get_current_win()
      vim.wo.wrap = true
      vim.wo.linebreak = true
      vim.bo[chat_buffer].bufhidden = 'wipe'
      -- Scroll to bottom
      local lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
      vim.api.nvim_win_set_cursor(chat_window, { #lines, 0 })
    end
  else
    print("no chat buffer to show")
  end
end

-- Wipe chat buffer and clear it
M.wipe_chat = function()
  -- Cancel running query
  if running_process then
    running_process:kill()
    running_process = nil
  end
  -- Close the chat window and buffer if it exists
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    vim.api.nvim_buf_delete(chat_buffer, { force = true })
    chat_buffer = nil
    chat_window = nil
  end
end

-- Cancel running queries
M.cancel_query = function()
  if running_process then
    running_process:kill()
    running_process = nil

    -- Update the buffer to remove thinking message
    if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
      local current_lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
      for i = #current_lines, 1, -1 do
        if current_lines[i] == '## Thinking...' then
          current_lines[i] = '# Cancelled'
          break
        end
      end
      vim.api.nvim_buf_set_lines(chat_buffer, 0, -1, false, current_lines)
    end
  else
    print("no running query to cancel")
  end
end

-- Setup function for plugin initialization
M.setup = function()
  vim.api.nvim_create_user_command('CodeBridgeTmux', M.send_to_claude_tmux, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeQuery', M.claude_query, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeChat', function(opts)
    opts.args = 'no-context'
    M.claude_query(opts)
  end, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeHide', M.hide_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeShow', M.show_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeWipe', M.wipe_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeCancelQuery', M.cancel_query, {})
end

return M
