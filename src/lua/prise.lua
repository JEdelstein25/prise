local M = {}

function M.Terminal(opts)
    return {
        type = "terminal",
        pty = opts.pty,
        ratio = opts.ratio,
        id = opts.id,
        show_cursor = opts.show_cursor,
    }
end

function M.Text(opts)
    if type(opts) == "string" then
        return {
            type = "text",
            content = { opts },
        }
    end

    -- If it has numeric keys, treat it as the content array directly
    if opts[1] then
        return {
            type = "text",
            content = opts,
        }
    end

    -- If it has a 'text' key but not 'content', treat it as a single segment
    if opts.text and not opts.content then
        return {
            type = "text",
            content = { opts },
        }
    end

    return {
        type = "text",
        content = opts.content or {},
        show_cursor = opts.show_cursor,
    }
end

function M.Column(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "column",
            children = opts,
        }
    end

    return {
        type = "column",
        children = opts.children or opts,
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        show_cursor = opts.show_cursor,
    }
end

function M.Row(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "row",
            children = opts,
        }
    end

    return {
        type = "row",
        children = opts.children or opts,
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        show_cursor = opts.show_cursor,
    }
end

return M
