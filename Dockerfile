FROM ruby:3.3

COPY . /app
WORKDIR /app

RUN bundle install

ENTRYPOINT ["ruby", "run.rb"]
