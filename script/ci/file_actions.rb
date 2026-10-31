module FileFixtures
  class Upload < Hamster::Action::Base
    def call
      file = context.uploads.fetch("file").first
      response = send_data(file.io, filename: file.filename)
      response[1]["x-title"] = context.form.fetch("title").join(",")
      response
    end
  end
  class Download < Hamster::Action::Base
    def call
      send_file("download.bin", root: ENV.fetch("HAMSTER_FILE_ROOT"))
    end
  end
end
