# Getting Started

This guide is an introduction to [git.limo](https://github.com/edmondFrank/gitgud), a Git repository web service written in Elixir.

This umbrella project is split into three applications:

* `:gitrekt` - Low-level Git functionalities written in C available as NIFs (see `GitRekt.Git`). It also provides native support for Git [transfer protocols]() and [PACK format]().
* `:gitgud` - Defines database schemas such as `GitGud.User` and `GitGud.Repo` and provides building-blocks for authentication, authorization, Git SSH and HTTP [transport protocols](), etc.
* `:gitgud_web` - Web-frontend similar to the one offered by [GitHub](https://github.com) providing a user-friendly management tool for Git repositories. It also features a [GraphQL API]().

In the following sections, we will provide an overview of those components and how they interact with each other. Feel free to access their respective module documentation for more specific examples, options and configuration.
