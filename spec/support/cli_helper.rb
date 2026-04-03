require 'open3'

module CLIHelper
  def bin
    File.expand_path('../../bin/wayback_archiver', __dir__)
  end

  def run_cli(*args, stdin_data: nil, env: {})
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, bin, *args, stdin_data: stdin_data)
    [stdout, stderr, status]
  end
end
