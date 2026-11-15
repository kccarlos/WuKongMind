import Foundation

/// A snapshot of today's browse tool texts (WukongMind/ToolRegistry+Browse.swift on main), so the
/// spike no longer compiles the app's VoiceTools.swift, which now needs the whole tool registry.
enum AppText {
    static let findHint = "Search matches words, so search a forum in its own language even when the user speaks another language."
    static let authors = "\"user\" with user shows only that author's posts; \"op\" only the opening poster's; "
    static let examples = "\"only what the original poster said\", \"just alice's posts\", \"show me the best answers\" or \"back to everything\""
    static let find = """
    Search the forum the user is on, or only the open topic, and show the hits on screen as numbered cards, best first. \
    Call it when the user asks to find, look for or search something, or asks whether anyone wrote about something. It \
    only shows cards: questions about what people think or recommend go to hand_off_to_agent. \
    Pass a few distinctive words in the forum's language (the topic brief says which): \(findHint) \
    Scope "topic" searches inside the open topic \
    ("where did someone mention the firmware version"). The result lists the hits by number with title, author and a line. \
    If one hit clearly fits, call browse_open with its card number right away, without asking. If several could fit, say \
    the titles of the top two or three and let the user pick; they are on the cards. If nothing matched, say so and offer \
    other words. Never read out ids, post numbers in bulk or URLs.
    """
    static let open = """
    Open a topic and land on a post. Pass card for a card from the last search_forum or hand-off, or topic_id for a \
    topic whose id you got from a result; pass neither to stay in the open topic. at says where to land: "post" with \
    post, "solution" for the accepted answer, "last" for the newest post, "top" for the most liked posts, "unread" for \
    the first post the user hasn't seen. Call it at once when the user asks to go somewhere ("take me to the solution", \
    "open the second one", "show me the latest reply"); navigation can be undone, so don't ask first. The result says \
    what is on screen and carries the landing post's text. Tell the user in a few words where you are and give the \
    gist; the post is on screen, so don't read it out unless the result says reading is fine.
    """
    static let move = """
    Move along the current list (the cards from the last search or focus) or around the open topic. action: "next" or \
    "previous" along the list, "back" or "forward" in the browser's history, "post" with post to go to post N of the \
    open topic, "top" for the first post, "bottom" for the last. Call it right away for "next", "go back", "post 37" or \
    "the first post". The result carries the post now on screen: say in a few words where you are and what it says, \
    without reading it out. At the end of the list, say so.
    """
    static let focus = """
    Narrow the open topic. mode: \(authors)\
    "top" the most liked posts; "posts" with posts highlights those posts as a tour, starting at the first; "clear" \
    shows the whole topic again. The focused posts become the current list, so "next" moves along them. Call it for \
    \(examples). \
    The result says how many posts there are and carries the first one's text: give the user the count and the gist.
    """
    static let read = """
    Get the full text of a post in the open topic: post N, or the current post when post is left out; scope "visible" \
    returns every post on screen. Only call it when the user asks about a post whose text you haven't received in a \
    note or a tool result; posts you navigated to already came with their text. Answer only from what it returns, \
    never from a guess.
    """
    static let end = """
    End the voice conversation, when the user says goodbye, that's all, or asks you to stop listening. Say a short \
    goodbye first, then call it.
    """
}
